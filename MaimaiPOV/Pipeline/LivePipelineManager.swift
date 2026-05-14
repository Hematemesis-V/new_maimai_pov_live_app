import SwiftUI
import Combine
import AVFoundation
import CoreMedia
import Metal
import simd
import QuartzCore
import UIKit
import CoreImage

class LivePipelineManager: ObservableObject {
    @Published var focusValue: Double = 0.5
    @Published var shutterTimescale: Double = 244.0
    @Published var isoValue: Double = 2000.0
    @Published var minISO: Double = 50.0
    @Published var maxISO: Double = 3200.0
    @Published var selectedLens: LensType = .main

    @Published var syncOffsetMs: Double = Config.syncOffsetMs
    @Published var readoutTimeMs: Double = Config.readoutTimeMs
    @Published var audioDelayMs: Double = Config.audioDelayMs

    @Published var fov: Float = 100.0
    @Published var distRatio: Float = 0.0
    @Published var yaw: Float = 0.0
    @Published var pitch: Float = 0.0
    @Published var roll: Float = 0.0
    @Published var stabEnabled: Bool = true
    @Published var lagMs: Double = 0

    @Published var yoloEnabled: Bool = true
    @Published var yoloPadding: Double = Double(Config.yoloPadding)
    @Published var yoloPreviewEnabled: Bool = Config.yoloPreviewEnabled

    @Published var trackAlpha: Double = Double(Config.defaultAlpha)
    @Published var trackMaxSpeed: Double = Double(Config.defaultMaxSpeed)
    @Published var trackDeadZone: Double = Double(Config.defaultDeadZone)
    @Published var trackTargetRatio: Double = Double(Config.defaultTargetRatio)

    @Published var currentFPS: Double = 0

    let camera = CameraCaptureManager()
    let debug = DebugInfoManager.shared
    let device: MTLDevice = MTLCreateSystemDefaultDevice()!
    let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    let streamManager = RTMPStreamManager()

    var stabilizer: MetalStabilizer?
    var yoloDetector: YOLODetector?
    var cropRenderer: CropRenderer?
    var smoothTracker = SmoothTracker()
    var latestTrackOutput: SmoothTracker.TrackOutput?

    var onStreamBufferAvailable: ((CVPixelBuffer, CMTime) -> Void)?
    var onAudioSampleAvailable: ((CMSampleBuffer) -> Void)?

    var previewTexture: MTLTexture? {
        if let cr = cropRenderer {
            return cr.outputTexture
        }
        return stabilizer?.outputTexture
    }

    var isCropActive: Bool { cropRenderer != nil }

    let pipelineQueue = DispatchQueue(label: "com.maimai.pipeline", qos: .userInteractive)

    private var textureReadback: TextureReadback?
    private var frameCount: Int = 0
    private var streamFrameCount: Int = 0
    private var fpsTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    init() {
        camera.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }.store(in: &cancellables)

        debug.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }.store(in: &cancellables)

        streamManager.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }.store(in: &cancellables)
    }

    @MainActor func start() {
        let lensCfg = LensCalibration.config(for: selectedLens, inputWidth: Config.inputWidth)
        let stab = MetalStabilizer(device: device, lensConfig: lensCfg)
        stab?.stabilizerEnabled = stabEnabled
        stab?.fov = fov
        stab?.useRollingShutter = true
        self.stabilizer = stab

        debug.fov = fov
        debug.distRatio = distRatio
        debug.stabEnabled = stabEnabled
        debug.lensType = selectedLens.rawValue
        debug.log("Pipeline initialized: \(selectedLens.rawValue)")

        let cropR = CropRenderer(device: device)
        self.cropRenderer = cropR

        textureReadback = TextureReadback(device: device,
                                           width: Config.outputWidth,
                                           height: Config.outputHeight)

        trackAlpha = Double(smoothTracker.alpha)
        trackMaxSpeed = Double(smoothTracker.maxSpeed)
        trackDeadZone = Double(smoothTracker.deadZone)
        trackTargetRatio = Double(smoothTracker.targetRatio)

        let detector = YOLODetector(device: device)
        self.yoloDetector = detector
        var yoloPreviewFrameCount = 0
        if detector != nil {
            detector?.onDetection = { [weak self] result in
                guard let self = self else { return }
                DispatchQueue.main.async {
                    self.debug.yoloDetected = result.detected
                    self.debug.yoloConfidence = result.confidence
                    self.debug.yoloInferenceMs = result.inferenceMs
                    self.debug.yoloPreprocessMs = result.preprocessMs
                    self.debug.yoloRawCoord = result.detected
                        ? String(format: "%.0f,%.0f,%.0f,%.0f",
                            result.rawYoloCx, result.rawYoloCy, result.rawYoloW, result.rawYoloH)
                        : "--"
                    self.debug.yoloStabCoord = result.detected
                        ? String(format: "%.0f,%.0f,%.0f,%.0f",
                            result.stabCx, result.stabCy, result.stabW, result.stabH)
                        : "--"
                    self.debug.yoloBoxesInfo = "\(result.innerScreenBoxesCount)/\(result.allBoxesCount)"
                    self.debug.yoloTopBoxes = result.topBoxes
                    self.debug.yoloBestRank = result.bestBoxRank

                    let track = self.smoothTracker.update(
                        detected: result.detected,
                        stabCx: result.stabCx,
                        stabCy: result.stabCy,
                        stabW: result.stabW,
                        stabH: result.stabH
                    )
                    self.latestTrackOutput = track
                    self.debug.trackCx = track.cx
                    self.debug.trackCy = track.cy
                    self.debug.trackCropW = track.cropW
                    self.debug.trackCropH = track.cropH
                    self.debug.trackSmoothCx = track.smoothCx
                    self.debug.trackSmoothCy = track.smoothCy
                    self.debug.trackSmoothW = track.smoothW
                    self.debug.trackSmoothH = track.smoothH
                    self.debug.trackState = track.state

                    if self.yoloPreviewEnabled {
                        yoloPreviewFrameCount += 1
                        if yoloPreviewFrameCount % 10 == 0,
                           let pb = self.yoloDetector?.previewPixelBuffer {
                            let ciImage = CIImage(cvPixelBuffer: pb)
                            if let cgImage = self.ciContext.createCGImage(ciImage, from: ciImage.extent) {
                                self.debug.yoloPreviewImage = UIImage(cgImage: cgImage)
                            }
                        }
                    } else {
                        self.debug.yoloPreviewImage = nil
                    }
                }
            }
            detector?.start()
            debug.log("YOLO detector initialized and started")
        }

        let u = YOLOPreprocessUniforms(padding: Config.yoloPadding)
        debug.yoloUniforms = String(format: "s%.3f pH%.0f pV%.0f pL%.0f pT%.0f",
            u.scale, u.padH, u.padV, u.padLeft, u.padTop)

        camera.checkPermissionAndStart()
        camera.setFocus(Float(focusValue))
        MotionManager.shared.startUpdates()

        camera.onVideoFrame = { [weak self] pixelBuffer, alignedTime in
            self?.pipelineQueue.async {
                guard let self = self else { return }
                self.frameCount += 1
                guard let stab = self.stabilizer, stab.stabilizerEnabled else { return }

                let centerTime = alignedTime + (Config.syncOffsetMs / 1000.0)
                let topTime    = centerTime - (Config.readoutTimeMs / 2000.0)
                let bottomTime = centerTime + (Config.readoutTimeMs / 2000.0)

                guard let qCenter = MotionManager.shared.getQuaternion(at: centerTime),
                      let qTop    = MotionManager.shared.getQuaternion(at: topTime),
                      let qBottom = MotionManager.shared.getQuaternion(at: bottomTime) else { return }

                let start = CACurrentMediaTime()
                stab.process(pixelBuffer: pixelBuffer, qCenter: qCenter, qTop: qTop, qBottom: qBottom)
                let elapsed = CACurrentMediaTime() - start

                if self.yoloEnabled, let detector = self.yoloDetector {
                    detector.enqueue(stabTexture: stab.outputTexture)
                }

                if let cr = self.cropRenderer {
                    if let track = self.latestTrackOutput {
                        cr.process(stabTexture: stab.outputTexture,
                                   cx: track.cx, cy: track.cy,
                                   cropW: track.cropW, cropH: track.cropH)
                    } else {
                        let fb = cr.makeFallbackTrack()
                        cr.process(stabTexture: stab.outputTexture,
                                   cx: fb.cx, cy: fb.cy,
                                   cropW: fb.cropW, cropH: fb.cropH)
                    }
                }

                if let readback = self.textureReadback,
                   let cr = self.cropRenderer,
                   let pixelBuffer = readback.read(from: cr.outputTexture) {
                    let timestamp = CMTime(seconds: alignedTime, preferredTimescale: 1000000000)
                    self.streamFrameCount += 1
                    self.onStreamBufferAvailable?(pixelBuffer, timestamp)
                    self.streamManager.appendVideo(pixelBuffer: pixelBuffer, timestamp: timestamp)
                }

                DispatchQueue.main.async {
                    self.lagMs = elapsed * 1000.0
                    self.debug.stabLagMs = elapsed * 1000.0
                }
            }
        }

        camera.onAudioSample = { [weak self] sample in
            self?.onAudioSampleAvailable?(sample)
            self?.streamManager.appendAudio(sampleBuffer: sample)
        }

        startFPSTimer()
    }

    func stop() {
        camera.onVideoFrame = nil
        camera.stopRunning()
        MotionManager.shared.stopUpdates()
        yoloDetector?.stop()
        stopFPSTimer()
    }

    private func startFPSTimer() {
        fpsTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.pipelineQueue.async {
                guard let self = self else { return }
                let count = self.frameCount
                let streamCount = self.streamFrameCount
                self.frameCount = 0
                self.streamFrameCount = 0
                DispatchQueue.main.async {
                    self.currentFPS = Double(count)
                    self.debug.fps = Double(count)
                    self.debug.frameCount = count
                    self.debug.streamInfo = "\(streamCount) bufs/s 720x1280"
                }
            }
        }
    }

    private func stopFPSTimer() {
        fpsTimer?.invalidate()
        fpsTimer = nil
    }

    @MainActor func handleLensChange(_ newLens: LensType) {
        camera.switchLens(to: newLens)
        reconfigureLens()
        debug.lensType = newLens.rawValue
    }

    func reconfigureLens() {
        let cfg = LensCalibration.config(for: selectedLens, inputWidth: Config.inputWidth)
        stabilizer?.loadLensConfig(cfg)
        fov = cfg.defaultFov
        stabilizer?.fov = cfg.defaultFov
    }

    func applyExposure() {
        guard camera.exposureMode == .custom else { return }
        camera.setExposure(duration: CMTime(value: 1, timescale: Int32(shutterTimescale)), iso: Float(isoValue))
    }

    func updateISORange() {
        let actualMin = Double(camera.getMinISO()), actualMax = Double(camera.getMaxISO())
        guard actualMin > 0, actualMax > actualMin else { return }
        minISO = actualMin; maxISO = actualMax
        if isoValue < actualMin || isoValue > actualMax { isoValue = actualMin }
    }

    @MainActor func updateStabilizerEnabled() {
        stabilizer?.stabilizerEnabled = stabEnabled
        debug.stabEnabled = stabEnabled
    }

    @MainActor func updateFov() {
        stabilizer?.fov = fov
        debug.fov = fov
    }

    @MainActor func updateDistRatio() {
        stabilizer?.distRatio = distRatio
        debug.distRatio = distRatio
    }

    func updateYaw() {
        stabilizer?.yaw = yaw
    }

    func updatePitch() {
        stabilizer?.pitch = pitch
    }

    func updateRoll() {
        stabilizer?.roll = roll
    }

    @MainActor func updateYoloPadding() {
        let pad = Int(yoloPadding)
        Config.yoloPadding = pad
        yoloDetector?.updatePadding(pad)
        debug.yoloPadding = pad
        let u = YOLOPreprocessUniforms(padding: pad)
        debug.yoloUniforms = String(format: "s%.3f pH%.0f pV%.0f pL%.0f pT%.0f",
            u.scale, u.padH, u.padV, u.padLeft, u.padTop)
    }

    @MainActor func updateYoloPreviewEnabled() {
        Config.yoloPreviewEnabled = yoloPreviewEnabled
    }

    @MainActor func updateTrackAlpha() {
        smoothTracker.alpha = Float(trackAlpha)
        debug.trackAlpha = Float(trackAlpha)
    }

    @MainActor func updateTrackMaxSpeed() {
        smoothTracker.maxSpeed = Float(trackMaxSpeed)
        debug.trackMaxSpeed = Float(trackMaxSpeed)
    }

    @MainActor func updateTrackDeadZone() {
        smoothTracker.deadZone = Float(trackDeadZone)
        debug.trackDeadZone = Float(trackDeadZone)
    }

    @MainActor func updateTrackTargetRatio() {
        smoothTracker.targetRatio = Float(trackTargetRatio)
        debug.trackTargetRatio = Float(trackTargetRatio)
    }

    @MainActor func updateReadoutTime() {
        stabilizer?.useRollingShutter = readoutTimeMs > 0
    }
}
