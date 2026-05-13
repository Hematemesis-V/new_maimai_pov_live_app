import Metal
import CoreVideo

class YOLOPreprocessor {

    let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLComputePipelineState
    private let uniformsBuffer: MTLBuffer
    private let uniforms: YOLOPreprocessUniforms

    private(set) var outputTexture: MTLTexture
    private var readbackBuffer: MTLBuffer

    let yoloSize: Int

    init?(device: MTLDevice) {
        self.device = device
        self.yoloSize = Config.yoloInputSize

        guard let queue = device.makeCommandQueue() else { return nil }
        self.commandQueue = queue

        guard let library = device.makeDefaultLibrary(),
              let kernel = library.makeFunction(name: "yoloPreprocess"),
              let ps = try? device.makeComputePipelineState(function: kernel) else {
            return nil
        }
        self.pipelineState = ps

        self.uniforms = YOLOPreprocessUniforms()
        self.uniformsBuffer = device.makeBuffer(
            length: MemoryLayout<YOLOPreprocessUniforms>.stride,
            options: .storageModeShared
        )!
        var u = self.uniforms
        memcpy(uniformsBuffer.contents(), &u, MemoryLayout<YOLOPreprocessUniforms>.stride)

        let size = Config.yoloInputSize
        let rowBytes = size * 4
        let bufferSize = rowBytes * size

        guard let buffer = device.makeBuffer(length: bufferSize, options: .storageModeShared) else { return nil }
        self.readbackBuffer = buffer

        let texDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: size,
            height: size,
            mipmapped: false
        )
        texDesc.usage = .shaderWrite
        texDesc.storageMode = .shared

        guard let tex = buffer.makeTexture(
            descriptor: texDesc,
            offset: 0,
            bytesPerRow: rowBytes
        ) else { return nil }
        self.outputTexture = tex
    }

    func process(stabOutputTexture: MTLTexture) -> CVPixelBuffer? {
        guard let cmdBuf = commandQueue.makeCommandBuffer(),
              let encoder = cmdBuf.makeComputeCommandEncoder() else { return nil }

        encoder.setComputePipelineState(pipelineState)
        encoder.setTexture(stabOutputTexture, index: 0)
        encoder.setTexture(outputTexture, index: 1)
        encoder.setBuffer(uniformsBuffer, offset: 0, index: 0)

        let tgSize = MTLSize(width: 16, height: 16, depth: 1)
        let gridSize = MTLSize(width: yoloSize, height: yoloSize, depth: 1)
        encoder.dispatchThreads(gridSize, threadsPerThreadgroup: tgSize)
        encoder.endEncoding()

        cmdBuf.commit()
        cmdBuf.waitUntilCompleted()

        return makeCVPixelBuffer()
    }

    private func makeCVPixelBuffer() -> CVPixelBuffer? {
        let size = yoloSize
        let srcRowBytes = size * 4

        var pixelBuffer: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]
        ]
        CVPixelBufferCreate(
            kCFAllocatorDefault,
            size, size,
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &pixelBuffer
        )

        guard let pb = pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }

        guard let dstBase = CVPixelBufferGetBaseAddress(pb) else { return nil }
        let dstRowBytes = CVPixelBufferGetBytesPerRow(pb)

        let srcBase = readbackBuffer.contents()

        if dstRowBytes == srcRowBytes {
            memcpy(dstBase, srcBase, srcRowBytes * size)
        } else {
            var srcPtr = srcBase
            var dstPtr = dstBase
            for _ in 0..<size {
                memcpy(dstPtr, srcPtr, srcRowBytes)
                srcPtr = srcPtr.advanced(by: srcRowBytes)
                dstPtr = dstPtr.advanced(by: dstRowBytes)
            }
        }

        return pb
    }
}
