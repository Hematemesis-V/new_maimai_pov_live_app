import Metal
import CoreVideo
import IOSurface

class YOLOPreprocessor {

    let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLComputePipelineState
    private let uniformsBuffer: MTLBuffer
    private var uniforms: YOLOPreprocessUniforms

    private var pixelBuffers: [CVPixelBuffer] = []
    private var outputTextures: [MTLTexture] = []
    private var bufferIndex: Int = 0

    let yoloSize: Int

    init?(device: MTLDevice, commandQueue: MTLCommandQueue, padding: Int = Config.yoloPadding) {
        self.device = device
        self.yoloSize = Config.yoloInputSize
        self.commandQueue = commandQueue

        guard let library = device.makeDefaultLibrary(),
              let kernel = library.makeFunction(name: "yoloPreprocess"),
              let ps = try? device.makeComputePipelineState(function: kernel) else {
            return nil
        }
        self.pipelineState = ps

        self.uniforms = YOLOPreprocessUniforms(padding: padding)
        self.uniformsBuffer = device.makeBuffer(
            length: MemoryLayout<YOLOPreprocessUniforms>.stride,
            options: .storageModeShared
        )!
        var u = self.uniforms
        memcpy(uniformsBuffer.contents(), &u, MemoryLayout<YOLOPreprocessUniforms>.stride)

        let size = Config.yoloInputSize
        let bytesPerRow = size * 4

        for _ in 0..<3 {
            let surfaceProps: [IOSurfacePropertyKey: Any] = [
                .width: size,
                .height: size,
                .pixelFormat: kCVPixelFormatType_32BGRA as UInt32,
                .bytesPerRow: bytesPerRow
            ]
            guard let surface = IOSurface(properties: surfaceProps) else { return nil }

            var pb: Unmanaged<CVPixelBuffer>?
            let err = CVPixelBufferCreateWithIOSurface(
                kCFAllocatorDefault,
                surface,
                nil,
                &pb
            )
            guard err == kCVReturnSuccess, let pixelBuffer = pb?.takeRetainedValue() else { return nil }

            let texDesc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm,
                width: size,
                height: size,
                mipmapped: false
            )
            texDesc.usage = .shaderWrite
            texDesc.storageMode = .shared

            guard let texture = device.makeTexture(descriptor: texDesc, iosurface: surface, plane: 0) else { return nil }

            pixelBuffers.append(pixelBuffer)
            outputTextures.append(texture)
        }
    }

    func updatePadding(_ padding: Int) {
        uniforms = YOLOPreprocessUniforms(padding: padding)
        var u = uniforms
        memcpy(uniformsBuffer.contents(), &u, MemoryLayout<YOLOPreprocessUniforms>.stride)
    }

    func process(stabOutputTexture: MTLTexture) -> CVPixelBuffer? {
        bufferIndex = (bufferIndex + 1) % pixelBuffers.count
        let outputTexture = outputTextures[bufferIndex]
        let pixelBuffer = pixelBuffers[bufferIndex]

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

        let sem = DispatchSemaphore(value: 0)
        cmdBuf.addCompletedHandler { _ in
            sem.signal()
        }
        cmdBuf.commit()
        sem.wait()

        return pixelBuffer
    }
}
