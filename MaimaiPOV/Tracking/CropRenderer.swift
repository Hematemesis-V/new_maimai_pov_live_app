import Metal

class CropRenderer {
    let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLComputePipelineState
    private let uniformsBuffer: MTLBuffer
    private(set) var outputTexture: MTLTexture

    let outWidth = Config.outputWidth
    let outHeight = Config.outputHeight
    let stabWidth = Float(Config.stabWidth)
    let stabHeight = Float(Config.stabHeight)

    init?(device: MTLDevice) {
        self.device = device

        guard let queue = device.makeCommandQueue() else { return nil }
        self.commandQueue = queue

        guard let library = device.makeDefaultLibrary(),
              let kernel = library.makeFunction(name: "cropAndResize"),
              let ps = try? device.makeComputePipelineState(function: kernel) else {
            return nil
        }
        self.pipelineState = ps

        self.uniformsBuffer = device.makeBuffer(
            length: MemoryLayout<CropUniforms>.stride,
            options: .storageModeShared
        )!

        let texDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: outWidth,
            height: outHeight,
            mipmapped: false
        )
        texDesc.usage = [.shaderWrite, .shaderRead]
        texDesc.storageMode = .private

        guard let tex = device.makeTexture(descriptor: texDesc) else { return nil }
        self.outputTexture = tex
    }

    func process(stabTexture: MTLTexture, cx: Float, cy: Float, cropW: Float, cropH: Float) {
        let halfW = cropW / 2.0
        let halfH = cropH / 2.0

        let cropX1 = cx - halfW
        let cropY1 = cy - halfH
        let cropX2 = cx + halfW
        let cropY2 = cy + halfH

        let actualCropW = max(cropX2 - cropX1, 1)
        let actualCropH = max(cropY2 - cropY1, 1)

        var uniforms = CropUniforms()
        uniforms.cropX1 = cropX1
        uniforms.cropY1 = cropY1
        uniforms.cropW = actualCropW
        uniforms.cropH = actualCropH
        uniforms.stabWidth = stabWidth
        uniforms.stabHeight = stabHeight
        uniforms.outWidth = Float(outWidth)
        uniforms.outHeight = Float(outHeight)

        memcpy(uniformsBuffer.contents(), &uniforms, MemoryLayout<CropUniforms>.stride)

        guard let cmdBuf = commandQueue.makeCommandBuffer(),
              let encoder = cmdBuf.makeComputeCommandEncoder() else { return }

        encoder.setComputePipelineState(pipelineState)
        encoder.setTexture(stabTexture, index: 0)
        encoder.setTexture(outputTexture, index: 1)
        encoder.setBuffer(uniformsBuffer, offset: 0, index: 0)

        let tgSize = MTLSize(width: 16, height: 16, depth: 1)
        let gridSize = MTLSize(width: outWidth, height: outHeight, depth: 1)
        encoder.dispatchThreads(gridSize, threadsPerThreadgroup: tgSize)
        encoder.endEncoding()

        cmdBuf.commit()
    }

    func makeFallbackTrack() -> (cx: Float, cy: Float, cropW: Float, cropH: Float) {
        let outputRatio = Float(outWidth) / Float(outHeight)
        let maxCropW = stabHeight * outputRatio
        let maxCropH = stabHeight
        return (stabWidth / 2.0, stabHeight / 2.0, maxCropW, maxCropH)
    }
}
