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

        guard let input = try? bestInput(
            image: pixelBuffer,
            iouThreshold: 0.45,
            confidenceThreshold: Double(Config.defaultConfidenceThreshold)
        ) else { return nil }
        guard let output = try? model.prediction(input: input) else { return nil }

        let elapsed = CACurrentMediaTime() - start

        let confidence = output.confidence
        let coordinates = output.coordinates

        let confShape = confidence.shape
        let numBoxes = confShape[0].intValue
        let numClasses = confShape[1].intValue

        let innerClass = 1
        let confThresh = Config.defaultConfidenceThreshold
        let yoloSize = Float(Config.yoloInputSize)

        let confPtr = UnsafeMutablePointer<Float>(OpaquePointer(confidence.dataPointer))
        let coordPtr = UnsafeMutablePointer<Float>(OpaquePointer(coordinates.dataPointer))
        let confStride = numClasses

        struct BoxInfo {
            let index: Int
            let conf: Float
            let nx: Float
            let ny: Float
            let nw: Float
            let nh: Float
            let area: Float
        }

        var innerBoxes: [BoxInfo] = []

        for i in 0..<numBoxes {
            let idx = i * confStride + innerClass
            guard idx < confidence.count else { continue }
            let c = confPtr[idx]
            if c >= confThresh {
                let nx = coordPtr[i * 4 + 0]
                let ny = coordPtr[i * 4 + 1]
                let nw = coordPtr[i * 4 + 2]
                let nh = coordPtr[i * 4 + 3]
                let area = nw * nh
                innerBoxes.append(BoxInfo(index: i, conf: c, nx: nx, ny: ny, nw: nw, nh: nh, area: area))
            }
        }

        let innerScreenCount = innerBoxes.count

        let sortedByArea = innerBoxes.sorted { $0.area > $1.area }

        var topBoxesStr = ""
        for (rank, box) in sortedByArea.prefix(3).enumerated() {
            if rank > 0 { topBoxesStr += " " }
            topBoxesStr += String(format: "%d:%.2f,%.2f,%.2f,%.2f,c%.2f",
                rank + 1, box.nx, box.ny, box.nw, box.nh, box.conf)
        }
        if topBoxesStr.isEmpty { topBoxesStr = "--" }

        var bestConf: Float = 0
        var bestIdx = -1
        for box in innerBoxes {
            if box.conf > bestConf {
                bestConf = box.conf
                bestIdx = box.index
            }
        }

        var bestBoxRank = 0
        if bestIdx >= 0 {
            for (rank, box) in sortedByArea.enumerated() {
                if box.index == bestIdx {
                    bestBoxRank = rank + 1
                    break
                }
            }
        }

        guard bestIdx >= 0 else {
            return DetectionResult(
                detected: false, confidence: 0,
                stabCx: 0, stabCy: 0, stabW: 0, stabH: 0,
                rawYoloCx: 0, rawYoloCy: 0, rawYoloW: 0, rawYoloH: 0,
                rawNx: 0, rawNy: 0, rawNw: 0, rawNh: 0,
                inferenceMs: elapsed * 1000.0, preprocessMs: preprocessMs,
                allBoxesCount: numBoxes, innerScreenBoxesCount: 0,
                topBoxes: topBoxesStr, bestBoxRank: 0
            )
        }

        let nx = coordPtr[bestIdx * 4 + 0]
        let ny = coordPtr[bestIdx * 4 + 1]
        let nw = coordPtr[bestIdx * 4 + 2]
        let nh = coordPtr[bestIdx * 4 + 3]

        let rawCx = nx * yoloSize
        let rawCy = ny * yoloSize
        let rawW = nw * yoloSize
        let rawH = nh * yoloSize

        if rawW < 5.0 || rawH < 5.0 || rawCx < 0 || rawCx > yoloSize || rawCy < 0 || rawCy > yoloSize {
            return DetectionResult(
                detected: false, confidence: bestConf,
                stabCx: 0, stabCy: 0, stabW: 0, stabH: 0,
                rawYoloCx: rawCx, rawYoloCy: rawCy, rawYoloW: rawW, rawYoloH: rawH,
                rawNx: nx, rawNy: ny, rawNw: nw, rawNh: nh,
                inferenceMs: elapsed * 1000.0, preprocessMs: preprocessMs,
                allBoxesCount: numBoxes, innerScreenBoxesCount: innerScreenCount,
                topBoxes: topBoxesStr, bestBoxRank: bestBoxRank
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
            allBoxesCount: numBoxes, innerScreenBoxesCount: innerScreenCount,
            topBoxes: topBoxesStr, bestBoxRank: bestBoxRank
        )
    }
}
