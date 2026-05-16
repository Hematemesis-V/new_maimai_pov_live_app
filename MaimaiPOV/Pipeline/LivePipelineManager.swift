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
    @Published var focusValue: Double = Config.focusValue
    @Published var shutterTimescale: Double = Config.shutterTimescale
    @Published var isoValue: Double = Config.isoValue
    @Published var minISO: Double = 50.0
    @Published var maxISO: Double = 3200.0
    @Published var selectedLens: LensType = Config.selectedLens

    @Published var syncOffsetMs: Double = Config.syncOffsetMs
    @Published var readoutTimeMs: Double = Config.readoutTimeMs

    @Published var fov: Float = Config.fov
    @Published var distRatio: Float = Config.distRatio
    @Published var yaw: Float = Config.yaw
    @Published var pitch: Float = Config.pitch
    @Published var roll: Float = Config.roll
    @Published var stabEnabled: Bool = Config.stabEnabled
    @Published var lagMs: Double = 0

    @Published var yoloEnabled: Bool = Config.yoloEnabled
    @Published var previewEnabled: Bool = Config.previewEnabled
    @Published var yoloPadding: Double = Double(Config.yoloPadding)
    @Published var yoloPreviewEnabled: Bool = Config.yoloPreviewEnabled

    @Published var trackAlpha: Double = Config.trackAlpha
    @Published var trackMaxSpeed: Double = Config.trackMaxSpeed
    @Published var trackDeadZone: Double = Config.trackDeadZone
    @Published var trackTargetRatio: Double = Config.trackTargetRatio

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
    var onAudioSampleAvailable: ((CMSampleBuffer, Double) -> Void)?

    var previewTexture: MTLTexture? {
        if previewEnabled {
            if let pool = ioSurfacePool, let buf = pool.lastCompletedBuffer {
                return buf.texture
            }
            if let cr = cropRenderer {
                return cr.outputTexture
            }
            return stabilizer?.outputTexture
        }
        return nil
    }

    var isCropActive: Bool { cropRenderer != nil }

    let pipelineQueue = DispatchQueue(label: "com.maimai.pipeline", qos: .userInteractive)

    private var ioSurfacePool: IOSurfaceOutputPool?
    private var frameCount: Int = 0
    private var streamFrameCount: Int = 0
    private var fpsTimer: Timer?
    private var temperatureTimer: Timer?
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
        // 1. 初始化稳定器，应用所有持久化设置
        let lensCfg = LensCalibration.config(for: selectedLens, inputWidth: Config.inputWidth)
        let stab = MetalStabilizer(device: device, lensConfig: lensCfg)
        stab?.stabilizerEnabled = stabEnabled
        stab?.fov = fov
        stab?.distRatio = distRatio
        stab?.yawDeg = yaw
        stab?.pitchDeg = pitch
        stab?.rollDeg = roll
        stab?.useRollingShutter = readoutTimeMs > 0
        self.stabilizer = stab

        debug.fov = fov
        debug.distRatio = distRatio
        debug.stabEnabled = stabEnabled
        debug.lensType = selectedLens.rawValue
        debug.log("Pipeline initialized: \(selectedLens.rawValue)")

        let cropR = CropRenderer(device: device)
        self.cropRenderer = cropR

        ioSurfacePool = IOSurfaceOutputPool(
            device: device,
            width: Config.outputWidth,
            height: Config.outputHeight
        )

        // 2. 初始化跟踪器，正确应用持久化设置（顺序要对！）
        smoothTracker.alpha = Float(trackAlpha)
        smoothTracker.maxSpeed = Float(trackMaxSpeed)
        smoothTracker.deadZone = Float(trackDeadZone)
        smoothTracker.targetRatio = Float(trackTargetRatio)
        debug.trackAlpha = Float(trackAlpha)
        debug.trackMaxSpeed = Float(trackMaxSpeed)
        debug.trackDeadZone = Float(trackDeadZone)
        debug.trackTargetRatio = Float(trackTargetRatio)

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

        // 3. 初始化相机，应用所有持久化设置
        camera.checkPermissionAndStart()
        camera.switchLens(to: selectedLens)
        camera.setFocus(Float(focusValue))
        applyExposure()
        MotionManager.shared.startUpdates()

        camera.onVideoFrame = { [weak self] pixelBuffer, alignedTime in
            let pipelineEnterTime = CACurrentMediaTime()
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

                stab.process(pixelBuffer: pixelBuffer, qCenter: qCenter, qTop: qTop, qBottom: qBottom)

                if self.yoloEnabled, let detector = self.yoloDetector {
                    detector.enqueue(stabTexture: stab.outputTexture)
                }

                if let pool = self.ioSurfacePool,
                   let cr = self.cropRenderer,
                   let writeBuffer = pool.nextWriteBuffer() {
                    let timestamp = CMTime(seconds: alignedTime, preferredTimescale: 1000000000)
                    let track: SmoothTracker.TrackOutput
                    if let t = self.latestTrackOutput {
                        track = t
                    } else {
                        let fb = cr.makeFallbackTrack()
                        track = SmoothTracker.TrackOutput(
                            cx: fb.cx, cy: fb.cy, cropW: fb.cropW, cropH: fb.cropH,
                            smoothCx: fb.cx, smoothCy: fb.cy, smoothW: fb.cropW, smoothH: fb.cropH,
                            detected: false, state: "fallback"
                        )
                    }
                    cr.process(
                        stabTexture: stab.outputTexture,
                        cx: track.cx, cy: track.cy,
                        cropW: track.cropW, cropH: track.cropH,
                        outputTexture: writeBuffer.texture
                    ) { [weak self] in
                        self?.pipelineQueue.async {
                            guard let self = self else { return }
                            self.streamFrameCount += 1
                            let pipelineLatencyMs = (CACurrentMediaTime() - pipelineEnterTime) * 1000.0
                            self.onStreamBufferAvailable?(writeBuffer.pixelBuffer, timestamp)
                            self.streamManager.appendVideo(pixelBuffer: writeBuffer.pixelBuffer, timestamp: timestamp)
                            DispatchQueue.main.async {
                                self.lagMs = pipelineLatencyMs
                                self.debug.pipelineLagMs = pipelineLatencyMs
                                self.debug.audioQueueDepth = self.streamManager.audioSyncQueueDepth
                            }
                        }
                    }
                } else if let cr = self.cropRenderer {
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
            }
        }

        camera.onAudioSample = { [weak self] sample, alignedTime in
            self?.onAudioSampleAvailable?(sample, alignedTime)
            self?.streamManager.appendAudio(sampleBuffer: sample, alignedTime: alignedTime)
        }

        startFPSTimer()
        startTemperatureTimer()
    }

    func stop() {
        camera.onVideoFrame = nil
        camera.stopRunning()
        MotionManager.shared.stopUpdates()
        yoloDetector?.stop()
        stopFPSTimer()
        stopTemperatureTimer()
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
        Config.selectedLens = newLens
        camera.switchLens(to: newLens)
        reconfigureLens()
        debug.lensType = newLens.rawValue
    }

    func reconfigureLens() {
        let cfg = LensCalibration.config(for: selectedLens, inputWidth: Config.inputWidth)
        stabilizer?.loadLensConfig(cfg)
        fov = cfg.defaultFov
        Config.fov = cfg.defaultFov
        stabilizer?.fov = cfg.defaultFov
    }

    func applyExposure() {
        Config.focusValue = focusValue
        Config.shutterTimescale = shutterTimescale
        Config.isoValue = isoValue
        guard camera.exposureMode == .custom else { return }
        camera.setExposure(duration: CMTime(value: 1, timescale: Int32(shutterTimescale)), iso: Float(isoValue))
    }

    func updateISORange() {
        let actualMin = Double(camera.getMinISO()), actualMax = Double(camera.getMaxISO())
        guard actualMin > 0, actualMax > actualMin else { return }
        minISO = actualMin; maxISO = actualMax
        if isoValue < actualMin || isoValue > actualMax { 
            isoValue = actualMin
            Config.isoValue = actualMin
        }
    }

    @MainActor func updateStabilizerEnabled() {
        Config.stabEnabled = stabEnabled
        stabilizer?.stabilizerEnabled = stabEnabled
        debug.stabEnabled = stabEnabled
    }

    @MainActor func updateFov() {
        Config.fov = fov
        stabilizer?.fov = fov
        debug.fov = fov
    }

    @MainActor func updateDistRatio() {
        Config.distRatio = distRatio
        stabilizer?.distRatio = distRatio
        debug.distRatio = distRatio
    }

    func updateYaw() {
        Config.yaw = yaw
        stabilizer?.yawDeg = yaw
    }

    func updatePitch() {
        Config.pitch = pitch
        stabilizer?.pitchDeg = pitch
    }

    func updateRoll() {
        Config.roll = roll
        stabilizer?.rollDeg = roll
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
        Config.trackAlpha = trackAlpha
        smoothTracker.alpha = Float(trackAlpha)
        debug.trackAlpha = Float(trackAlpha)
    }

    @MainActor func updateTrackMaxSpeed() {
        Config.trackMaxSpeed = trackMaxSpeed
        smoothTracker.maxSpeed = Float(trackMaxSpeed)
        debug.trackMaxSpeed = Float(trackMaxSpeed)
    }

    @MainActor func updateTrackDeadZone() {
        Config.trackDeadZone = trackDeadZone
        smoothTracker.deadZone = Float(trackDeadZone)
        debug.trackDeadZone = Float(trackDeadZone)
    }

    @MainActor func updateTrackTargetRatio() {
        Config.trackTargetRatio = trackTargetRatio
        smoothTracker.targetRatio = Float(trackTargetRatio)
        debug.trackTargetRatio = Float(trackTargetRatio)
    }

    @MainActor func updateReadoutTime() {
        Config.readoutTimeMs = readoutTimeMs
        stabilizer?.useRollingShutter = readoutTimeMs > 0
    }

    private func startTemperatureTimer() {
        temperatureTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.updateDeviceTemperature()
        }
        updateDeviceTemperature()
    }

    private func stopTemperatureTimer() {
        temperatureTimer?.invalidate()
        temperatureTimer = nil
    }

    private func updateDeviceTemperature() {
        DispatchQueue.main.async { [weak self] in
            self?.debug.deviceTemperature = 0.0
        }
    }
}
