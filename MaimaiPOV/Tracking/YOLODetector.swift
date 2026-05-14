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

    var onDetection: ((DetectionResult) -> Void)?

    init?(device: MTLDevice) {
        self.device = device
        guard let m = try? best(configuration: MLModelConfiguration()) else { return nil }
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
            while self.semaphore.wait(timeout: .now()) == .success {}
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

            autoreleasepool {
                stagingLock.lock()
                let readIdx = stagingReadIndex
                stagingLock.unlock()

                let stabTexture = stagingTextures[readIdx]

                let prepStart = CACurrentMediaTime()
                guard let pixelBuffer = preprocessor.process(stabOutputTexture: stabTexture) else { return }
                let prepElapsed = CACurrentMediaTime() - prepStart

                let result = infer(pixelBuffer, preprocessMs: prepElapsed * 1000.0)
                if let r = result {
                    onDetection?(r)
                }
            }
        }
    }

    private func infer(_ pixelBuffer: CVPixelBuffer, preprocessMs: Double) -> DetectionResult? {
        let start = CACurrentMediaTime()

        guard let input = try? bestInput(image: pixelBuffer) else { return nil }
        guard let output = try? model.prediction(input: input) else { return nil }

        let elapsed = CACurrentMediaTime() - start

        let featureProvider = output as? MLFeatureProvider
        guard let feature = featureProvider?.features.first,
              let multiArray = feature.multiArrayValue else { return nil }

        let shape = multiArray.shape
        guard shape.count == 3 else { return nil }
        let numFeatures = shape[1].intValue
        let numAnchors = shape[2].intValue

        let strides = multiArray.strides.map { $0.intValue }
        let dataPointer = multiArray.dataPointer

        let isFloat16 = multiArray.dataType == .float16

        let innerClassIdx = 5
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
                let conf = Float(_Float16(bitPattern: confRaw))
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
            nx = Float(_Float16(bitPattern: ptr[0 * featStride + bestAnchor * anchorStride]))
            ny = Float(_Float16(bitPattern: ptr[1 * featStride + bestAnchor * anchorStride]))
            nw = Float(_Float16(bitPattern: ptr[2 * featStride + bestAnchor * anchorStride]))
            nh = Float(_Float16(bitPattern: ptr[3 * featStride + bestAnchor * anchorStride]))
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
        let rawCx = nx * yoloSize
        let rawCy = ny * yoloSize
        let rawW = nw * yoloSize
        let rawH = nh * yoloSize

        let topBoxesStr = String(format: "1:%.3f,%.3f,%.3f,%.3f,c%.2f", nx, ny, nw, nh, bestConf)

        if rawW < 5.0 || rawH < 5.0 {
            return DetectionResult(
                detected: false, confidence: bestConf,
                stabCx: 0, stabCy: 0, stabW: 0, stabH: 0,
                rawYoloCx: rawCx, rawYoloCy: rawCy, rawYoloW: rawW, rawYoloH: rawH,
                rawNx: nx, rawNy: ny, rawNw: nw, rawNh: nh,
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
            rawNx: nx, rawNy: ny, rawNw: nw, rawNh: nh,
            inferenceMs: elapsed * 1000.0, preprocessMs: preprocessMs,
            allBoxesCount: numAnchors, innerScreenBoxesCount: aboveThreshCount,
            topBoxes: topBoxesStr, bestBoxRank: 1
        )
    }
}
