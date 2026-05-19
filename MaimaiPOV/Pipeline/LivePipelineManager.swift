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
    @Published var yoloOverlayEnabled: Bool = Config.yoloOverlayEnabled
    @Published var yoloOverlayScale: Double = Config.yoloOverlayScale
    @Published var yoloTargetFPS: Double = Config.yoloTargetFPS

    @Published var trackTargetRatio: Double = Config.trackTargetRatio
    @Published var trackRecenterSpeed: Double = Config.trackRecenterSpeed

    @Published var currentFPS: Double = 0

    let camera = CameraCaptureManager()
    let debug = DebugInfoManager.shared
    let device: MTLDevice = MTLCreateSystemDefaultDevice()!
    let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    let sharedCommandQueue: MTLCommandQueue
    let streamManager = RTMPStreamManager()

    var stabilizer: MetalStabilizer?
    var yoloDetector: YOLODetector?
    var cropRenderer: CropRenderer?
    var bboxTracker = BBoxTracker()
    var latestTrackOutput: BBoxTracker.TrackOutput?

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
    
    var stabTexture: MTLTexture? {
        stabilizer?.outputTexture
    }

    var isCropActive: Bool { cropRenderer != nil }

    let pipelineQueue = DispatchQueue(label: "com.maimai.pipeline", qos: .userInteractive)

    private var ioSurfacePool: IOSurfaceOutputPool?
    private var frameCount: Int = 0
    private var streamFrameCount: Int = 0
    private var fpsTimer: Timer?
    private var temperatureTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private var yoloPreviewFrameCount: Int = 0

    init() {
        sharedCommandQueue = device.makeCommandQueue()!

        camera.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }.store(in: &cancellables)

        streamManager.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }.store(in: &cancellables)

        streamManager.$isStreaming.sink { [weak self] streaming in
            DispatchQueue.main.async {
                self?.debug.isStreaming = streaming
            }
        }.store(in: &cancellables)
    }

    @MainActor func start() {
        let lensCfg = LensCalibration.config(for: selectedLens, inputWidth: Config.inputWidth)
        let stab = MetalStabilizer(device: device, commandQueue: sharedCommandQueue, lensConfig: lensCfg)
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

        let cropR = CropRenderer(device: device, commandQueue: sharedCommandQueue)
        self.cropRenderer = cropR

        ioSurfacePool = IOSurfaceOutputPool(
            device: device,
            width: Config.outputWidth,
            height: Config.outputHeight
        )

        bboxTracker.targetRatio = Float(trackTargetRatio)
        bboxTracker.recenterSpeed = Float(trackRecenterSpeed)
        debug.trackTargetRatio = Float(trackTargetRatio)
        debug.trackRecenterSpeed = Float(trackRecenterSpeed)

        let detector = YOLODetector(device: device, commandQueue: sharedCommandQueue)
        self.yoloDetector = detector
        detector?.targetFPS = yoloTargetFPS
        if detector != nil {
            debug.log("YOLO detector initialized (sync mode)")
        }

        let u = YOLOPreprocessUniforms(padding: Config.yoloPadding)
        debug.yoloUniforms = String(format: "s%.3f pH%.0f pV%.0f pL%.0f pT%.0f",
            u.scale, u.padH, u.padV, u.padLeft, u.padTop)
        debug.yoloOverlayEnabled = Config.yoloOverlayEnabled
        debug.yoloOverlayScale = Config.yoloOverlayScale

        camera.checkPermissionAndStart()
        camera.switchLens(to: selectedLens)
        camera.onDeviceReady = { [weak self] in
            guard let self else { return }
            self.camera.setFocus(Float(self.focusValue))
            self.applyExposure()
        }
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

                var detectionResult: YOLODetector.DetectionResult?

                if self.yoloEnabled, let detector = self.yoloDetector {
                    let shouldRunYOLO = detector.advanceSkipCounter()

                    if shouldRunYOLO {
                        let prepStart = CACurrentMediaTime()

                        guard let cmdBuf = self.sharedCommandQueue.makeCommandBuffer(),
                              let encoder = cmdBuf.makeComputeCommandEncoder() else {
                            stab.process(pixelBuffer: pixelBuffer, qCenter: qCenter, qTop: qTop, qBottom: qBottom)
                            stab.waitForCompletion()
                            return
                        }

                        stab.encode(into: encoder, pixelBuffer: pixelBuffer, qCenter: qCenter, qTop: qTop, qBottom: qBottom)

                        if let yoloPixelBuffer = detector.preprocessor.encode(into: encoder, stabOutputTexture: stab.outputTexture) {
                            encoder.endEncoding()

                            let sem = DispatchSemaphore(value: 0)
                            cmdBuf.addCompletedHandler { _ in
                                sem.signal()
                            }
                            cmdBuf.commit()
                            sem.wait()

                            let prepElapsed = (CACurrentMediaTime() - prepStart) * 1000.0
                            detectionResult = detector.detectWithPreprocessedPixelBuffer(yoloPixelBuffer, preprocessMs: prepElapsed)
                        } else {
                            encoder.endEncoding()

                            let sem = DispatchSemaphore(value: 0)
                            cmdBuf.addCompletedHandler { _ in
                                sem.signal()
                            }
                            cmdBuf.commit()
                            sem.wait()
                        }
                    } else {
                        stab.process(pixelBuffer: pixelBuffer, qCenter: qCenter, qTop: qTop, qBottom: qBottom)
                        stab.waitForCompletion()
                    }
                } else {
                    stab.process(pixelBuffer: pixelBuffer, qCenter: qCenter, qTop: qTop, qBottom: qBottom)
                    stab.waitForCompletion()
                }

                var yoloPreviewImage: UIImage?
                let track: BBoxTracker.TrackOutput
                if let result = detectionResult {
                    track = self.bboxTracker.update(
                        detected: result.detected,
                        stabCx: result.stabCx,
                        stabCy: result.stabCy,
                        stabW: result.stabW,
                        stabH: result.stabH
                    )
                    self.latestTrackOutput = track

                    if self.yoloPreviewEnabled {
                        self.yoloPreviewFrameCount += 1
                        if self.yoloPreviewFrameCount % 30 == 0,
                           let pb = self.yoloDetector?.previewPixelBuffer {
                            let ciImage = CIImage(cvPixelBuffer: pb)
                            if let cgImage = self.ciContext.createCGImage(ciImage, from: ciImage.extent) {
                                yoloPreviewImage = UIImage(cgImage: cgImage)
                            }
                        }
                    }
                } else if self.latestTrackOutput != nil {
                    track = self.bboxTracker.freeze()
                } else if let cr = self.cropRenderer {
                    let fb = cr.makeFallbackTrack()
                    track = BBoxTracker.TrackOutput(
                        cx: fb.cx, cy: fb.cy, cropW: fb.cropW, cropH: fb.cropH,
                        detected: false, state: "fallback"
                    )
                } else {
                    let stabW = Float(Config.stabWidth)
                    let stabH = Float(Config.stabHeight)
                    track = BBoxTracker.TrackOutput(
                        cx: stabW / 2.0, cy: stabH / 2.0,
                        cropW: stabH * (9.0 / 16.0), cropH: stabH,
                        detected: false, state: "nofallback"
                    )
                }

                let resultCopy = detectionResult
                let previewEnabled = self.yoloPreviewEnabled
                DispatchQueue.main.async {
                    var snapshot = DebugInfoManager.FrameDebugData()
                    if let result = resultCopy {
                        snapshot.hasYoloResult = true
                        snapshot.yoloDetected = result.detected
                        snapshot.yoloConfidence = result.confidence
                        snapshot.yoloInferenceMs = result.inferenceMs
                        snapshot.yoloPreprocessMs = result.preprocessMs
                        snapshot.rawYoloCx = result.rawYoloCx
                        snapshot.rawYoloCy = result.rawYoloCy
                        snapshot.rawYoloW = result.rawYoloW
                        snapshot.rawYoloH = result.rawYoloH
                        snapshot.stabCx = result.stabCx
                        snapshot.stabCy = result.stabCy
                        snapshot.stabW = result.stabW
                        snapshot.stabH = result.stabH
                        snapshot.innerScreenBoxesCount = result.innerScreenBoxesCount
                        snapshot.allBoxesCount = result.allBoxesCount
                        snapshot.topBoxes = result.topBoxes
                        snapshot.bestBoxRank = result.bestBoxRank
                        snapshot.yoloPreviewImage = previewEnabled ? yoloPreviewImage : nil
                    }
                    snapshot.trackCx = track.cx
                    snapshot.trackCy = track.cy
                    snapshot.trackCropW = track.cropW
                    snapshot.trackCropH = track.cropH
                    snapshot.trackState = track.state
                    self.debug.stageFrameData(snapshot)
                }

                if let pool = self.ioSurfacePool,
                   let cr = self.cropRenderer,
                   let writeBuffer = pool.nextWriteBuffer() {
                    let timestamp = CMTime(seconds: alignedTime, preferredTimescale: 1000000000)
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
                                self.debug.stageLagData(ms: pipelineLatencyMs, audioDepth: self.streamManager.audioSyncQueueDepth)
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
                    let pipelineLatencyMs = (CACurrentMediaTime() - pipelineEnterTime) * 1000.0
                    DispatchQueue.main.async {
                        self.lagMs = pipelineLatencyMs
                        self.debug.stageLagData(ms: pipelineLatencyMs, audioDepth: 0)
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
        debug.startFlushTimer()
    }

    func stop() {
        camera.onVideoFrame = nil
        camera.stopRunning()
        MotionManager.shared.stopUpdates()
        stopFPSTimer()
        stopTemperatureTimer()
        DispatchQueue.main.async {
            self.debug.stopFlushTimer()
        }
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
                    self.debug.yoloActualFPS = self.yoloDetector?.actualFPS ?? 0
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
        camera.onDeviceReady = { [weak self] in
            guard let self else { return }
            self.camera.setFocus(Float(self.focusValue))
            self.applyExposure()
        }
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
        camera.setFocus(Float(focusValue))
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
    
    @MainActor func updateYoloOverlayEnabled() {
        Config.yoloOverlayEnabled = yoloOverlayEnabled
        debug.yoloOverlayEnabled = yoloOverlayEnabled
    }
    
    @MainActor func updateYoloOverlayScale() {
        Config.yoloOverlayScale = yoloOverlayScale
        debug.yoloOverlayScale = yoloOverlayScale
    }

    @MainActor func updateYoloTargetFPS() {
        Config.yoloTargetFPS = yoloTargetFPS
        yoloDetector?.targetFPS = yoloTargetFPS
        debug.yoloTargetFPS = yoloTargetFPS
    }

    @MainActor func updateTrackTargetRatio() {
        Config.trackTargetRatio = trackTargetRatio
        bboxTracker.targetRatio = Float(trackTargetRatio)
        debug.trackTargetRatio = Float(trackTargetRatio)
    }

    @MainActor func updateTrackRecenterSpeed() {
        Config.trackRecenterSpeed = trackRecenterSpeed
        bboxTracker.recenterSpeed = Float(trackRecenterSpeed)
        debug.trackRecenterSpeed = Float(trackRecenterSpeed)
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
