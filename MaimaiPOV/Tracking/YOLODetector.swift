import CoreML
import CoreVideo
import Metal
import QuartzCore

class YOLODetector {

    struct DetectionResult {
        var detected: Bool
        var confidence: Float
        var stabCx: Float
        var stabCy: Float
        var stabW: Float
        var stabH: Float
        var rawYoloCx: Float
        var rawYoloCy: Float
        var rawYoloW: Float
        var rawYoloH: Float
        var rawNx: Float
        var rawNy: Float
        var rawNw: Float
        var rawNh: Float
        var inferenceMs: Double
        var preprocessMs: Double
        var allBoxesCount: Int
        var innerScreenBoxesCount: Int
        var topBoxes: String
        var bestBoxRank: Int
    }

    private let model: best
    private var uniforms: YOLOPreprocessUniforms
    private let yoloQueue = DispatchQueue(label: "com.maimai.yolo", qos: .userInitiated)
    private var running = false
    private let semaphore = DispatchSemaphore(value: 0)
    private let preprocessor: YOLOPreprocessor

    private let device: MTLDevice
    private let stagingCommandQueue: MTLCommandQueue
    private let stagingTextures: [MTLTexture]
    private var stagingWriteIndex: Int = 0
    private var stagingReadIndex: Int = 0
    private let stagingLock = NSLock()
    private let frameLock = NSLock()
    private var hasNewFrame = false

    var onDetection: ((DetectionResult) -> Void)?

    var targetFPS: Double = Config.yoloTargetFPS
    private var lastEnqueueTime: Double = 0
    private var inferenceCount: Int = 0
    private var inferenceCountStartTime: Double = 0
    private(set) var actualFPS: Double = 0

    private var lastPixelBuffer: CVPixelBuffer?
    var previewPixelBuffer: CVPixelBuffer? {
        stagingLock.lock()
        let pb = lastPixelBuffer
        stagingLock.unlock()
        return pb
    }

    init?(device: MTLDevice) {
        self.device = device
        let config = MLModelConfiguration()
        config.computeUnits = .cpuAndNeuralEngine
        guard let m = try? best(configuration: config) else { return nil }
        self.model = m
        self.uniforms = YOLOPreprocessUniforms(padding: Config.yoloPadding)

        guard let prep = YOLOPreprocessor(device: device) else { return nil }
        self.preprocessor = prep

        guard let queue = device.makeCommandQueue() else { return nil }
        self.stagingCommandQueue = queue

        var textures: [MTLTexture] = []
        for _ in 0..<2 {
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba8Unorm,
                width: Config.stabWidth,
                height: Config.stabHeight,
                mipmapped: false
            )
            desc.usage = .shaderRead
            desc.storageMode = .private
            guard let tex = device.makeTexture(descriptor: desc) else { return nil }
            textures.append(tex)
        }
        self.stagingTextures = textures
    }

    func start() {
        guard !running else { return }
        running = true
        yoloQueue.async { [weak self] in
            self?.inferenceLoop()
        }
    }

    func stop() {
        running = false
        semaphore.signal()
    }

    func enqueue(stabTexture: MTLTexture) {
        let now = CACurrentMediaTime()
        let minInterval = 1.0 / (max(targetFPS, 1.0) + 2.0)
        if lastEnqueueTime > 0, now - lastEnqueueTime < minInterval {
            return
        }
        lastEnqueueTime = now

        let writeIdx = stagingWriteIndex
        let targetTexture = stagingTextures[writeIdx]

        guard let cmdBuf = stagingCommandQueue.makeCommandBuffer(),
              let blit = cmdBuf.makeBlitCommandEncoder() else { return }

        blit.copy(
            from: stabTexture,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: stabTexture.width, height: stabTexture.height, depth: 1),
            to: targetTexture,
            destinationSlice: 0,
            destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
        )
        blit.endEncoding()

        cmdBuf.addCompletedHandler { [weak self] _ in
            guard let self = self else { return }
            self.stagingLock.lock()
            self.stagingReadIndex = writeIdx
            self.stagingLock.unlock()
            self.frameLock.lock()
            self.hasNewFrame = true
            self.frameLock.unlock()
            self.semaphore.signal()
        }
        cmdBuf.commit()

        stagingWriteIndex = (writeIdx + 1) % stagingTextures.count
    }

    func updatePadding(_ padding: Int) {
        preprocessor.updatePadding(padding)
        uniforms = YOLOPreprocessUniforms(padding: padding)
    }

    private func inferenceLoop() {
        while running {
            semaphore.wait()

            frameLock.lock()
            let hasFrame = hasNewFrame
            hasNewFrame = false
            frameLock.unlock()

            if !hasFrame { continue }

            autoreleasepool {
                stagingLock.lock()
                let readIdx = stagingReadIndex
                stagingLock.unlock()

                let stabTexture = stagingTextures[readIdx]

                let prepStart = CACurrentMediaTime()
                guard let pixelBuffer = preprocessor.process(stabOutputTexture: stabTexture) else { return }
                lastPixelBuffer = pixelBuffer
                let prepElapsed = CACurrentMediaTime() - prepStart

                let result = infer(pixelBuffer, preprocessMs: prepElapsed * 1000.0)
                if let r = result {
                    updateActualFPS()
                    onDetection?(r)
                }
            }
        }
    }

    private func updateActualFPS() {
        let now = CACurrentMediaTime()
        inferenceCount += 1
        if inferenceCountStartTime <= 0 {
            inferenceCountStartTime = now
        }
        let elapsed = now - inferenceCountStartTime
        if elapsed >= 1.0 {
            actualFPS = Double(inferenceCount) / elapsed
            inferenceCount = 0
            inferenceCountStartTime = now
        }
    }

    private func infer(_ pixelBuffer: CVPixelBuffer, preprocessMs: Double) -> DetectionResult? {
        let start = CACurrentMediaTime()

        guard let input = try? bestInput(image: pixelBuffer) else { return nil }
        guard let output = try? model.prediction(input: input) else { return nil }

        let elapsed = CACurrentMediaTime() - start

        let featureProvider = output as MLFeatureProvider
        guard let featureName = featureProvider.featureNames.first,
              let featureValue = featureProvider.featureValue(for: featureName),
              let multiArray = featureValue.multiArrayValue else { return nil }

        let shape = multiArray.shape
        guard shape.count == 3 else { return nil }
        let numFeatures = shape[1].intValue
        let numAnchors = shape[2].intValue

        let strides = multiArray.strides.map { $0.intValue }
        let dataPointer = multiArray.dataPointer

        let isFloat16 = multiArray.dataType == MLMultiArrayDataType.float16

        let innerClassIdx = 4
        let confThresh = Config.defaultConfidenceThreshold

        var bestConf: Float = 0
        var bestAnchor = -1
        var aboveThreshCount = 0

        if isFloat16 {
            let ptr = dataPointer.assumingMemoryBound(to: UInt16.self)
            let fStride = strides[0]
            let featStride = strides[1]
            let anchorStride = strides[2]

            for a in 0..<numAnchors {
                let confRaw = ptr[innerClassIdx * featStride + a * anchorStride]
                let conf = Float(Float16(bitPattern: confRaw))
                if conf >= confThresh {
                    aboveThreshCount += 1
                    if conf > bestConf {
                        bestConf = conf
                        bestAnchor = a
                    }
                }
            }
        } else {
            let ptr = dataPointer.assumingMemoryBound(to: Float.self)
            let fStride = strides[0]
            let featStride = strides[1]
            let anchorStride = strides[2]

            for a in 0..<numAnchors {
                let conf = ptr[innerClassIdx * featStride + a * anchorStride]
                if conf >= confThresh {
                    aboveThreshCount += 1
                    if conf > bestConf {
                        bestConf = conf
                        bestAnchor = a
                    }
                }
            }
        }

        guard bestAnchor >= 0 else {
            return DetectionResult(
                detected: false, confidence: 0,
                stabCx: 0, stabCy: 0, stabW: 0, stabH: 0,
                rawYoloCx: 0, rawYoloCy: 0, rawYoloW: 0, rawYoloH: 0,
                rawNx: 0, rawNy: 0, rawNw: 0, rawNh: 0,
                inferenceMs: elapsed * 1000.0, preprocessMs: preprocessMs,
                allBoxesCount: numAnchors, innerScreenBoxesCount: 0,
                topBoxes: "--", bestBoxRank: 0
            )
        }

        var nx: Float = 0, ny: Float = 0, nw: Float = 0, nh: Float = 0

        if isFloat16 {
            let ptr = dataPointer.assumingMemoryBound(to: UInt16.self)
            let featStride = strides[1]
            let anchorStride = strides[2]
            nx = Float(Float16(bitPattern: ptr[0 * featStride + bestAnchor * anchorStride]))
            ny = Float(Float16(bitPattern: ptr[1 * featStride + bestAnchor * anchorStride]))
            nw = Float(Float16(bitPattern: ptr[2 * featStride + bestAnchor * anchorStride]))
            nh = Float(Float16(bitPattern: ptr[3 * featStride + bestAnchor * anchorStride]))
        } else {
            let ptr = dataPointer.assumingMemoryBound(to: Float.self)
            let featStride = strides[1]
            let anchorStride = strides[2]
            nx = ptr[0 * featStride + bestAnchor * anchorStride]
            ny = ptr[1 * featStride + bestAnchor * anchorStride]
            nw = ptr[2 * featStride + bestAnchor * anchorStride]
            nh = ptr[3 * featStride + bestAnchor * anchorStride]
        }

        let yoloSize = Float(Config.yoloInputSize)
        let rawCx = nx
        let rawCy = ny
        let rawW = nw
        let rawH = nh

        let normNx = nx / yoloSize
        let normNy = ny / yoloSize
        let normNw = nw / yoloSize
        let normNh = nh / yoloSize

        let topBoxesStr = String(format: "1:%.3f,%.3f,%.3f,%.3f,c%.2f", normNx, normNy, normNw, normNh, bestConf)

        if rawW < 5.0 || rawH < 5.0 {
            return DetectionResult(
                detected: false, confidence: bestConf,
                stabCx: 0, stabCy: 0, stabW: 0, stabH: 0,
                rawYoloCx: rawCx, rawYoloCy: rawCy, rawYoloW: rawW, rawYoloH: rawH,
                rawNx: normNx, rawNy: normNy, rawNw: normNw, rawNh: normNh,
                inferenceMs: elapsed * 1000.0, preprocessMs: preprocessMs,
                allBoxesCount: numAnchors, innerScreenBoxesCount: aboveThreshCount,
                topBoxes: topBoxesStr, bestBoxRank: 1
            )
        }

        let stabCx = (rawCx - uniforms.padLeft) / uniforms.scale - uniforms.padH
        let stabCy = (rawCy - uniforms.padTop) / uniforms.scale - uniforms.padV
        let stabW = rawW / uniforms.scale
        let stabH = rawH / uniforms.scale

        return DetectionResult(
            detected: true, confidence: bestConf,
            stabCx: stabCx, stabCy: stabCy, stabW: stabW, stabH: stabH,
            rawYoloCx: rawCx, rawYoloCy: rawCy, rawYoloW: rawW, rawYoloH: rawH,
            rawNx: normNx, rawNy: normNy, rawNw: normNw, rawNh: normNh,
            inferenceMs: elapsed * 1000.0, preprocessMs: preprocessMs,
            allBoxesCount: numAnchors, innerScreenBoxesCount: aboveThreshCount,
            topBoxes: topBoxesStr, bestBoxRank: 1
        )
    }
}
