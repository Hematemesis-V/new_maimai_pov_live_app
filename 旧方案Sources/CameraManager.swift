import AVFoundation
import Photos
import SwiftUI
import UIKit

class CameraManager: NSObject, ObservableObject {

    enum LensType: String, CaseIterable {
        case main = "Main (1x)"
        case ultraWide = "Ultra Wide (0.5x)"

        var deviceType: AVCaptureDevice.DeviceType {
            switch self {
            case .main:      return .builtInWideAngleCamera
            case .ultraWide: return .builtInUltraWideCamera
            }
        }
    }

    let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    let movieFileOutput = AVCaptureMovieFileOutput()
    private let sessionQueue = DispatchQueue(label: "com.maimai.camera", qos: .userInteractive)

    @Published var isRunning = false
    @Published var awbLocked = false
    @Published var cameraAuthorized = false
    @Published var activeLens: LensType = .main
    @Published var isRecording = false
    @Published var exposureMode: AVCaptureDevice.ExposureMode = .custom

    private var currentDevice: AVCaptureDevice?
    private var currentInput: AVCaptureDeviceInput?
    private var recordingActive = false
    private var currentDuration: CMTime = CMTime(value: 1, timescale: 240)
    private var currentISO: Float = 0.0

    var onFrame: ((CVPixelBuffer, Double) -> Void)?
    private var clockOffset: Double? = nil

    override init() {
        super.init()
    }

    deinit {
        if session.isRunning {
            session.stopRunning()
        }
    }

    func startRunning() {
        sessionQueue.async { [weak self] in
            guard let self, !self.session.isRunning else { return }
            self.session.startRunning()
            DispatchQueue.main.async { self.isRunning = self.session.isRunning }
        }
    }

    func stopRunning() {
        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
            DispatchQueue.main.async { self.isRunning = self.session.isRunning }
        }
    }

    func checkPermissionAndStart() {
        let videoStatus = AVCaptureDevice.authorizationStatus(for: .video)
        let audioStatus = AVCaptureDevice.authorizationStatus(for: .audio)

        if videoStatus == .authorized && audioStatus == .authorized {
            self.setupAndStart()
        } else {
            AVCaptureDevice.requestAccess(for: .video) { [weak self] videoGranted in
                AVCaptureDevice.requestAccess(for: .audio) { audioGranted in
                    DispatchQueue.main.async {
                        self?.cameraAuthorized = videoGranted
                    }
                    if videoGranted && audioGranted {
                        self?.setupAndStart()
                    } else {
                        print("CameraManager: Video or Audio permission denied")
                    }
                }
            }
        }
    }

    private func setupAndStart() {
        DispatchQueue.main.async { self.cameraAuthorized = true }
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.configureSession(for: self.activeLens)
            self.session.startRunning()
            DispatchQueue.main.async { self.isRunning = self.session.isRunning }
        }
    }

    private func configureSession(for lens: LensType) {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        if let existing = currentInput {
            session.removeInput(existing)
            currentInput = nil
        }

        guard let device = AVCaptureDevice.default(lens.deviceType, for: .video, position: .back) else {
            print("CameraManager: No \(lens.rawValue) camera")
            return
        }
        currentDevice = device

        guard let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            print("CameraManager: Cannot add input for \(lens.rawValue)")
            return
        }
        session.addInput(input)
        currentInput = input

        configureFormat(for: device)

        if !session.outputs.contains(where: { $0 is AVCaptureVideoDataOutput }) {
            videoOutput.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            ]
            videoOutput.alwaysDiscardsLateVideoFrames = true

            guard session.canAddOutput(videoOutput) else {
                print("CameraManager: Cannot add video output")
                return
            }
            session.addOutput(videoOutput)

            for connection in videoOutput.connections {
                if connection.isVideoStabilizationSupported {
                    connection.preferredVideoStabilizationMode = .off
                }
            }

            videoOutput.setSampleBufferDelegate(self, queue: sessionQueue)
        }

        if !session.outputs.contains(where: { $0 is AVCaptureMovieFileOutput }) {
            guard session.canAddOutput(movieFileOutput) else {
                print("CameraManager: Cannot add movie file output")
                return
            }
            session.addOutput(movieFileOutput)

            for connection in movieFileOutput.connections {
                if connection.isVideoStabilizationSupported {
                    connection.preferredVideoStabilizationMode = .off
                }
            }
        }

        configureExposure(for: device)

        if !session.outputs.contains(where: { $0 is AVCaptureAudioDataOutput }) {
            let audioSession = AVAudioSession.sharedInstance()
            try? audioSession.setCategory(.playAndRecord, mode: .videoRecording, options: [.defaultToSpeaker, .allowBluetooth])
            try? audioSession.setActive(true)

            if let inputs = audioSession.availableInputs {
                let builtInMic = inputs.first(where: { $0.portType == .builtInMic })
                if let dataSources = builtInMic?.dataSources {
                    let backMic = dataSources.first(where: { $0.orientation == .back })
                    try? builtInMic?.setPreferredDataSource(backMic)
                    if let supportedPatterns = backMic?.supportedPolarPatterns, supportedPatterns.contains(.cardioid) {
                        try? backMic?.setPreferredPolarPattern(.cardioid)
                    }
                }
            }

            guard let audioDevice = AVCaptureDevice.default(for: .audio),
                  let audioInput = try? AVCaptureDeviceInput(device: audioDevice),
                  session.canAddInput(audioInput) else {
                print("CameraManager: Cannot add audio input")
                return
            }
            session.addInput(audioInput)

            guard session.canAddOutput(audioOutput) else {
                print("CameraManager: Cannot add audio output")
                return
            }
            session.addOutput(audioOutput)
            audioOutput.setSampleBufferDelegate(self, queue: sessionQueue)
        }
    }

    func switchLens(to lens: LensType) {
        guard lens != activeLens else { return }
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.configureSession(for: lens)
            DispatchQueue.main.async { self.activeLens = lens }
        }
    }

    private func configureFormat(for device: AVCaptureDevice) {
        var bestFormat: AVCaptureDevice.Format?
        var bestWidth: Int32 = 0

        for format in device.formats {
            let dims = format.formatDescription.dimensions
            let ratio = Double(dims.width) / Double(dims.height)
            guard abs(ratio - 4.0 / 3.0) < 0.01 else { continue }

            let supports60 = format.videoSupportedFrameRateRanges.contains {
                $0.maxFrameRate >= 60.0
            }
            guard supports60 else { continue }

            if dims.width > bestWidth {
                bestFormat = format
                bestWidth = dims.width
            }
        }

        guard let format = bestFormat else {
            print("CameraManager: No 4:3 60fps format found")
            return
        }

        do {
            try device.lockForConfiguration()
            device.activeFormat = format
            let fps60 = CMTime(value: 1, timescale: 60)
            device.activeVideoMinFrameDuration = fps60
            device.activeVideoMaxFrameDuration = fps60
            
            if device.isGeometricDistortionCorrectionSupported {
                device.isGeometricDistortionCorrectionEnabled = false
                print("CameraManager: 🚫 Geometric Distortion Correction DISABLED")
            }
            
            device.unlockForConfiguration()
            let d = format.formatDescription.dimensions
            print("CameraManager: Format \(d.width)x\(d.height) @ 60fps locked")
        } catch {
            print("CameraManager: Format config failed: \(error)")
        }
    }

    private func configureExposure(for device: AVCaptureDevice) {
        guard device.isExposureModeSupported(.custom) else {
            print("CameraManager: Custom exposure not supported")
            return
        }
        do {
            try device.lockForConfiguration()
            currentISO = Float(device.activeFormat.minISO)
            let duration = currentDuration
            device.setExposureModeCustom(duration: duration, iso: currentISO, completionHandler: nil)
            device.unlockForConfiguration()
            DispatchQueue.main.async { self.exposureMode = .custom }
            print("CameraManager: Exposure locked 1/\(duration.timescale)s, ISO=\(currentISO)")
        } catch {
            print("CameraManager: Exposure config failed: \(error)")
        }
    }

    func setExposure(duration: CMTime, iso: Float) {
        guard let device = currentDevice,
              device.isExposureModeSupported(.custom) else { return }
        do {
            try device.lockForConfiguration()
            let clampedISO = min(max(iso, Float(device.activeFormat.minISO)), Float(device.activeFormat.maxISO))
            device.setExposureModeCustom(duration: duration, iso: clampedISO, completionHandler: nil)
            currentDuration = duration
            currentISO = clampedISO
            device.unlockForConfiguration()
        } catch {
            print("CameraManager: Exposure set failed: \(error)")
        }
    }

    func setAutoExposure() {
        guard let device = currentDevice,
              device.isExposureModeSupported(.continuousAutoExposure) else { return }
        do {
            try device.lockForConfiguration()
            device.exposureMode = .continuousAutoExposure
            device.unlockForConfiguration()
            DispatchQueue.main.async { self.exposureMode = .continuousAutoExposure }
        } catch {
            print("CameraManager: Auto exposure failed: \(error)")
        }
    }

    func setCustomExposure() {
        guard let device = currentDevice,
              device.isExposureModeSupported(.custom) else { return }
        do {
            try device.lockForConfiguration()
            device.setExposureModeCustom(duration: currentDuration, iso: currentISO, completionHandler: nil)
            device.unlockForConfiguration()
            DispatchQueue.main.async { self.exposureMode = .custom }
        } catch {
            print("CameraManager: Custom exposure failed: \(error)")
        }
    }

    func getMinISO() -> Float {
        guard let device = currentDevice else { return 0 }
        return Float(device.activeFormat.minISO)
    }

    func getMaxISO() -> Float {
        guard let device = currentDevice else { return 0 }
        return Float(device.activeFormat.maxISO)
    }

    func getActiveMinDuration() -> CMTime {
        guard let device = currentDevice else { return CMTime(value: 1, timescale: 1) }
        return device.activeFormat.minExposureDuration
    }

    func getActiveMaxDuration() -> CMTime {
        guard let device = currentDevice else { return CMTime(value: 1, timescale: 1) }
        return device.activeFormat.maxExposureDuration
    }

    func setFocus(_ value: Float) {
        guard let device = currentDevice,
              device.isFocusModeSupported(.locked) else { return }
        do {
            try device.lockForConfiguration()
            device.setFocusModeLocked(lensPosition: value, completionHandler: nil)
            device.unlockForConfiguration()
        } catch {
            print("CameraManager: Focus set failed: \(error)")
        }
    }

    func lockWhiteBalance() {
        guard let device = currentDevice else { return }
        do {
            try device.lockForConfiguration()
            device.setWhiteBalanceModeLocked(with: device.deviceWhiteBalanceGains, completionHandler: nil)
            device.unlockForConfiguration()
            DispatchQueue.main.async { self.awbLocked = true }
        } catch {
            print("CameraManager: WB lock failed: \(error)")
        }
    }

    func unlockWhiteBalance() {
        guard let device = currentDevice else { return }
        do {
            try device.lockForConfiguration()
            device.whiteBalanceMode = .continuousAutoWhiteBalance
            device.unlockForConfiguration()
            DispatchQueue.main.async { self.awbLocked = false }
        } catch {
            print("CameraManager: WB unlock failed: \(error)")
        }
    }

    func startRecording() {
        guard !recordingActive else { return }

        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let filename = "calib_\(Int(Date().timeIntervalSince1970)).mov"
        let fileURL = docs.appendingPathComponent(filename)

        recordingActive = true
        DispatchQueue.main.async { self.isRecording = true }

        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.movieFileOutput.startRecording(to: fileURL, recordingDelegate: self)
        }
        print("CameraManager: Recording to \(fileURL.lastPathComponent)")
    }

    func stopRecording() {
        guard recordingActive else { return }
        recordingActive = false
        movieFileOutput.stopRecording()
    }
}

extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        if output is AVCaptureAudioDataOutput {
            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
            let length = CMBlockBufferGetDataLength(blockBuffer)
            var pcmData = Data(count: length)
            _ = pcmData.withUnsafeMutableBytes { dest in
                CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: length, destination: dest.baseAddress!)
            }

            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            let timestamp = Double(pts.value) / Double(pts.timescale)

            NetworkManager.shared.sendAudio(pcmData: pcmData, timestamp: timestamp)
            return
        }

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let frameTime = CMTimeGetSeconds(timestamp)
        let systemTime = ProcessInfo.processInfo.systemUptime
        
        if clockOffset == nil {
            clockOffset = systemTime - frameTime
        } else {
            clockOffset = clockOffset! * 0.99 + (systemTime - frameTime) * 0.01
        }
        
        let alignedFrameTime = frameTime + clockOffset!
        
        onFrame?(pixelBuffer, alignedFrameTime)
    }
}

extension CameraManager: AVCaptureFileOutputRecordingDelegate {

    func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        DispatchQueue.main.async { self.isRecording = false }

        if let error {
            print("CameraManager: Recording failed: \(error.localizedDescription)")
            return
        }

        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized else {
                print("CameraManager: Photo library access denied")
                return
            }
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: outputFileURL)
            }) { success, error in
                if success {
                    print("CameraManager: Saved to photo library: \(outputFileURL.lastPathComponent)")
                } else {
                    print("CameraManager: Save failed: \(error?.localizedDescription ?? "unknown")")
                }
            }
        }
    }
}

class PreviewView: UIView {
    override class var layerClass: AnyClass {
        AVCaptureVideoPreviewLayer.self
    }

    var previewLayer: AVCaptureVideoPreviewLayer {
        layer as! AVCaptureVideoPreviewLayer
    }
}

struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        view.previewLayer.connection?.videoOrientation = .portrait
        view.backgroundColor = .black
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}
}
