import CoreML
import CoreVideo
import Vision

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
        var inferenceMs: Double
    }

    private let model: best
    private let uniforms: YOLOPreprocessUniforms
    private let yoloQueue = DispatchQueue(label: "com.maimai.yolo", qos: .userInitiated)
    private var latestBuffer: CVPixelBuffer?
    private let bufferLock = NSLock
    private var running = false
    private let semaphore = DispatchSemaphore(value: 0)

    var onDetection: ((DetectionResult) -> Void)?

    init?() {
        guard let m = try? best(configuration: MLModelConfiguration()) else { return nil }
        self.model = m
        self.uniforms = YOLOPreprocessUniforms(padding: Config.yoloPadding)
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

    func enqueue(_ pixelBuffer: CVPixelBuffer) {
        bufferLock.lock()
        latestBuffer = pixelBuffer
        bufferLock.unlock()
        semaphore.signal()
    }

    private func inferenceLoop() {
        while running {
            semaphore.wait()

            bufferLock.lock()
            guard let buffer = latestBuffer else {
                bufferLock.unlock()
                continue
            }
            latestBuffer = nil
            bufferLock.unlock()

            let result = infer(buffer)
            if let r = result {
                onDetection?(r)
            }
        }
    }

    private func infer(_ pixelBuffer: CVPixelBuffer) -> DetectionResult? {
        let start = CACurrentMediaTime()

        guard let input = try? bestInput(image: pixelBuffer) else { return nil }
        guard let output = try? model.prediction(input: input) else { return nil }

        let elapsed = CACurrentMediaTime() - start

        let confidence = output.confidence
        let coordinates = output.coordinates

        let confShape = confidence.shape
        let coordShape = coordinates.shape
        let numBoxes = confShape.dimensions[0]
        let numClasses = confShape.dimensions[1]

        let innerClass = 1
        let confThresh = Config.defaultConfidenceThreshold
        let yoloSize = Float(Config.yoloInputSize)

        var bestConf: Float = 0
        var bestIdx = -1

        let confPtr = UnsafeMutablePointer<Float>(OpaquePointer(confidence.dataPointer))
        for i in 0..<numBoxes {
            let c = confPtr[i * numClasses + innerClass]
            if c >= confThresh && c > bestConf {
                bestConf = c
                bestIdx = i
            }
        }

        guard bestIdx >= 0 else {
            return DetectionResult(
                detected: false, confidence: 0,
                stabCx: 0, stabCy: 0, stabW: 0, stabH: 0,
                rawYoloCx: 0, rawYoloCy: 0, rawYoloW: 0, rawYoloH: 0,
                inferenceMs: elapsed * 1000.0
            )
        }

        let coordPtr = UnsafeMutablePointer<Float>(OpaquePointer(coordinates.dataPointer))
        let nx = coordPtr[bestIdx * 4 + 0]
        let ny = coordPtr[bestIdx * 4 + 1]
        let nw = coordPtr[bestIdx * 4 + 2]
        let nh = coordPtr[bestIdx * 4 + 3]

        let rawCx = nx * yoloSize
        let rawCy = ny * yoloSize
        let rawW = nw * yoloSize
        let rawH = nh * yoloSize

        let stabCx = (rawCx - uniforms.padLeft) / uniforms.scale - uniforms.padH
        let stabCy = (rawCy - uniforms.padTop) / uniforms.scale - uniforms.padV
        let stabW = rawW / uniforms.scale
        let stabH = rawH / uniforms.scale

        return DetectionResult(
            detected: true, confidence: bestConf,
            stabCx: stabCx, stabCy: stabCy, stabW: stabW, stabH: stabH,
            rawYoloCx: rawCx, rawYoloCy: rawCy, rawYoloW: rawW, rawYoloH: rawH,
            inferenceMs: elapsed * 1000.0
        )
    }
}
