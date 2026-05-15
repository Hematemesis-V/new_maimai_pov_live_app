import AVFoundation
import SwiftUI

class CameraCaptureManager: NSObject, ObservableObject {

    let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private let sessionQueue = DispatchQueue(label: "com.maimai.camera", qos: .userInteractive)

    @Published var isRunning = false
    @Published var awbLocked = false
    @Published var cameraAuthorized = false
    @Published var activeLens: LensType = .main
    @Published var exposureMode: AVCaptureDevice.ExposureMode = .custom

    private var currentDevice: AVCaptureDevice?
    private var currentInput: AVCaptureDeviceInput?
    private var currentDuration: CMTime = CMTime(value: 1, timescale: 240)
    private var currentISO: Float = 0.0

    var onVideoFrame: ((CVPixelBuffer, Double) -> Void)?
    var onAudioSample: ((CMSampleBuffer, Double) -> Void)?

    private var masterClock: CMClock?
    private let hostClock = CMClockGetHostTimeClock()

    func checkPermissionAndStart() {
        let videoStatus = AVCaptureDevice.authorizationStatus(for: .video)
        let audioStatus = AVCaptureDevice.authorizationStatus(for: .audio)

        if videoStatus == .authorized && audioStatus == .authorized {
            setupAndStart()
        } else {
            AVCaptureDevice.requestAccess(for: .video) { [weak self] videoGranted in
                AVCaptureDevice.requestAccess(for: .audio) { [weak self] audioGranted in
                    DispatchQueue.main.async {
                        self?.cameraAuthorized = videoGranted && audioGranted
                    }
                    if videoGranted && audioGranted {
                        self?.setupAndStart()
                    } else {
                        print("CameraCaptureManager: Permission denied")
                    }
                }
            }
        }
    }

    func startRunning() {
        sessionQueue.async { [weak self] in
            guard let self, !self.session.isRunning else { return }
            self.session.startRunning()
            self.masterClock = self.session.masterClock
            DispatchQueue.main.async { self.isRunning = true }
        }
    }

    func stopRunning() {
        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
            DispatchQueue.main.async { self.isRunning = false }
        }
    }

    func switchLens(to lens: LensType) {
        guard lens != activeLens else { return }
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.configureSession(for: lens)
            self.masterClock = self.session.masterClock
            DispatchQueue.main.async { self.activeLens = lens }
        }
    }

    // MARK: - Private setup

    private func setupAndStart() {
        DispatchQueue.main.async { self.cameraAuthorized = true }
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.configureSession(for: self.activeLens)
            self.configureAudioSession()
            self.session.startRunning()
            self.masterClock = self.session.masterClock
            DispatchQueue.main.async { self.isRunning = true }
        }
    }

    private func configureSession(for lens: LensType) {
        session.automaticallyConfiguresApplicationAudioSession = false

        session.beginConfiguration()
        defer { session.commitConfiguration() }

        if let existing = currentInput {
            session.removeInput(existing)
            currentInput = nil
        }

        guard let device = AVCaptureDevice.default(lens.deviceType, for: .video, position: .back) else {
            print("CameraCaptureManager: No \(lens.rawValue) camera")
            return
        }
        currentDevice = device

        guard let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            print("CameraCaptureManager: Cannot add input for \(lens.rawValue)")
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
                print("CameraCaptureManager: Cannot add video output")
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

        configureExposure(for: device)

        // Audio setup (once)
        if !session.outputs.contains(where: { $0 is AVCaptureAudioDataOutput }) {
            guard let audioDevice = AVCaptureDevice.default(for: .audio),
                  let audioInput = try? AVCaptureDeviceInput(device: audioDevice),
                  session.canAddInput(audioInput) else {
                print("CameraCaptureManager: Cannot add audio input")
                return
            }
            session.addInput(audioInput)

            guard session.canAddOutput(audioOutput) else {
                print("CameraCaptureManager: Cannot add audio output")
                return
            }
            session.addOutput(audioOutput)
            audioOutput.setSampleBufferDelegate(self, queue: sessionQueue)
        }
    }

    private func configureAudioSession() {
        let audioSession = AVAudioSession.sharedInstance()
        try? audioSession.setCategory(.playAndRecord, mode: .videoRecording, options: [.defaultToSpeaker, .allowBluetooth])
        try? audioSession.setActive(true)

        if let inputs = audioSession.availableInputs,
           let builtInMicInput = inputs.first(where: { $0.portType == .builtInMic }) {
            try? audioSession.setPreferredInput(builtInMicInput)

            if let dataSources = builtInMicInput.dataSources,
               let backMic = dataSources.first(where: { $0.orientation == .back }) {
                if let supportedPatterns = backMic.supportedPolarPatterns, supportedPatterns.contains(.cardioid) {
                    try? backMic.setPreferredPolarPattern(.cardioid)
                }
                try? builtInMicInput.setPreferredDataSource(backMic)
            }
        }

        try? audioSession.setPreferredInputOrientation(.portrait)
    }

    private func configureFormat(for device: AVCaptureDevice) {
        var bestFormat: AVCaptureDevice.Format?
        var bestWidth: Int32 = 0

        for format in device.formats {
            let dims = format.formatDescription.dimensions
            let ratio = Double(dims.width) / Double(dims.height)
            guard abs(ratio - 4.0 / 3.0) < 0.01 else { continue }
            guard format.videoSupportedFrameRateRanges.contains(where: { $0.maxFrameRate >= 60.0 }) else { continue }
            if dims.width > bestWidth {
                bestFormat = format
                bestWidth = dims.width
            }
        }

        guard let format = bestFormat else {
            print("CameraCaptureManager: No 4:3 60fps format found")
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
            }

            device.unlockForConfiguration()
            let d = format.formatDescription.dimensions
            print("CameraCaptureManager: Format \(d.width)x\(d.height) @ 60fps")
        } catch {
            print("CameraCaptureManager: Format config failed: \(error)")
        }
    }

    // MARK: - Exposure / Focus / White Balance

    private func configureExposure(for device: AVCaptureDevice) {
        guard device.isExposureModeSupported(.custom) else { return }
        do {
            try device.lockForConfiguration()
            currentISO = 2000.0
            let clampedISO = min(max(currentISO, Float(device.activeFormat.minISO)), Float(device.activeFormat.maxISO))
            device.setExposureModeCustom(duration: currentDuration, iso: clampedISO, completionHandler: nil)
            currentISO = clampedISO
            device.unlockForConfiguration()
            DispatchQueue.main.async { self.exposureMode = .custom }
        } catch {
            print("CameraCaptureManager: Exposure config failed: \(error)")
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
            print("CameraCaptureManager: Set exposure failed: \(error)")
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
        } catch {}
    }

    func setCustomExposure() {
        guard let device = currentDevice,
              device.isExposureModeSupported(.custom) else { return }
        do {
            try device.lockForConfiguration()
            device.setExposureModeCustom(duration: currentDuration, iso: currentISO, completionHandler: nil)
            device.unlockForConfiguration()
            DispatchQueue.main.async { self.exposureMode = .custom }
        } catch {}
    }

    func getMinISO() -> Float { currentDevice.map { Float($0.activeFormat.minISO) } ?? 0 }
    func getMaxISO() -> Float { currentDevice.map { Float($0.activeFormat.maxISO) } ?? 0 }
    func getActiveMinDuration() -> CMTime { currentDevice?.activeFormat.minExposureDuration ?? CMTime(value: 1, timescale: 1) }
    func getActiveMaxDuration() -> CMTime { currentDevice?.activeFormat.maxExposureDuration ?? CMTime(value: 1, timescale: 1) }

    func setFocus(_ value: Float) {
        guard let device = currentDevice,
              device.isFocusModeSupported(.locked) else { return }
        do {
            try device.lockForConfiguration()
            device.setFocusModeLocked(lensPosition: value, completionHandler: nil)
            device.unlockForConfiguration()
        } catch {
            print("CameraCaptureManager: Focus failed: \(error)")
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
            print("CameraCaptureManager: WB lock failed: \(error)")
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
            print("CameraCaptureManager: WB unlock failed: \(error)")
        }
    }
}

// MARK: - Sample Buffer Delegate

extension CameraCaptureManager: AVCaptureVideoDataOutputSampleBufferDelegate,
                                 AVCaptureAudioDataOutputSampleBufferDelegate {

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        if output is AVCaptureAudioDataOutput {
            handleAudioSample(sampleBuffer)
        } else {
            handleVideoSample(sampleBuffer)
        }
    }

    private func handleVideoSample(_ sampleBuffer: CMSampleBuffer) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        guard let masterClock else { return }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let hostTime = CMSyncConvertTime(pts, ofSourceClock: masterClock, toDestinationClock: hostClock)
        let alignedTime = CMTimeGetSeconds(hostTime)

        onVideoFrame?(pixelBuffer, alignedTime)
    }

    private func handleAudioSample(_ sampleBuffer: CMSampleBuffer) {
        guard let masterClock else { return }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let hostTime = CMSyncConvertTime(pts, ofSourceClock: masterClock, toDestinationClock: hostClock)
        let alignedTime = CMTimeGetSeconds(hostTime)

        onAudioSample?(sampleBuffer, alignedTime)
    }
}
