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
    private(set) var preprocessor: YOLOPreprocessor

    var targetFPS: Double = Config.yoloTargetFPS
    private(set) var frameSkipCounter: Int = 0
    private var inferenceCount: Int = 0
    private var inferenceCountStartTime: Double = 0
    private(set) var actualFPS: Double = 0

    private var lastPixelBuffer: CVPixelBuffer?
    var previewPixelBuffer: CVPixelBuffer? {
        return lastPixelBuffer
    }

    init?(device: MTLDevice, commandQueue: MTLCommandQueue) {
        let config = MLModelConfiguration()
        config.computeUnits = .cpuAndNeuralEngine
        guard let m = try? best(configuration: config) else { return nil }
        self.model = m
        self.uniforms = YOLOPreprocessUniforms(padding: Config.yoloPadding)

        guard let prep = YOLOPreprocessor(device: device, commandQueue: commandQueue) else { return nil }
        self.preprocessor = prep
    }

    func detect(stabTexture: MTLTexture) -> DetectionResult? {
        let skip = max(1, Int(round(60.0 / max(targetFPS, 1.0))))
        frameSkipCounter += 1
        if frameSkipCounter < skip {
            return nil
        }
        frameSkipCounter = 0

        let prepStart = CACurrentMediaTime()
        guard let pixelBuffer = preprocessor.process(stabOutputTexture: stabTexture) else {
            return nil
        }
        lastPixelBuffer = pixelBuffer
        let prepElapsed = CACurrentMediaTime() - prepStart

        let result = infer(pixelBuffer, preprocessMs: prepElapsed * 1000.0)
        if result != nil {
            updateActualFPS()
        }
        return result
    }

    func detectWithPreprocessedPixelBuffer(_ pixelBuffer: CVPixelBuffer, preprocessMs: Double) -> DetectionResult? {
        lastPixelBuffer = pixelBuffer
        let result = infer(pixelBuffer, preprocessMs: preprocessMs)
        if result != nil {
            updateActualFPS()
        }
        return result
    }

    func advanceSkipCounter() -> Bool {
        let skip = max(1, Int(round(60.0 / max(targetFPS, 1.0))))
        frameSkipCounter += 1
        if frameSkipCounter >= skip {
            frameSkipCounter = 0
            return true
        }
        return false
    }

    func updatePadding(_ padding: Int) {
        preprocessor.updatePadding(padding)
        uniforms = YOLOPreprocessUniforms(padding: padding)
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
