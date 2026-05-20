import Metal

class CropRenderer {
    let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLComputePipelineState
    private let uniformsBuffer: MTLBuffer
    private(set) lazy var outputTexture: MTLTexture = {
        let texDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: outWidth,
            height: outHeight,
            mipmapped: false
        )
        texDesc.usage = [.shaderWrite, .shaderRead]
        texDesc.storageMode = .private
        return device.makeTexture(descriptor: texDesc)!
    }()

    let outWidth = Config.outputWidth
    let outHeight = Config.outputHeight
    let stabWidth = Float(Config.stabWidth)
    let stabHeight = Float(Config.stabHeight)

    init?(device: MTLDevice, commandQueue: MTLCommandQueue) {
        self.device = device
        self.commandQueue = commandQueue

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
    }

    func process(stabTexture: MTLTexture, cx: Float, cy: Float, cropW: Float, cropH: Float) {
        process(stabTexture: stabTexture, cx: cx, cy: cy, cropW: cropW, cropH: cropH, outputTexture: outputTexture, completion: {})
    }

    func process(stabTexture: MTLTexture, cx: Float, cy: Float, cropW: Float, cropH: Float,
                 outputTexture: MTLTexture, completion: @escaping () -> Void) {
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

        cmdBuf.addCompletedHandler { _ in
            completion()
        }
        cmdBuf.commit()
    }

    func encode(into encoder: MTLComputeCommandEncoder,
                stabTexture: MTLTexture,
                cx: Float, cy: Float, cropW: Float, cropH: Float,
                outputTexture: MTLTexture) {
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

        encoder.setComputePipelineState(pipelineState)
        encoder.setTexture(stabTexture, index: 0)
        encoder.setTexture(outputTexture, index: 1)
        encoder.setBuffer(uniformsBuffer, offset: 0, index: 0)

        let tgSize = MTLSize(width: 16, height: 16, depth: 1)
        let gridSize = MTLSize(width: outWidth, height: outHeight, depth: 1)
        encoder.dispatchThreads(gridSize, threadsPerThreadgroup: tgSize)
    }

    func makeFallbackTrack() -> (cx: Float, cy: Float, cropW: Float, cropH: Float) {
        let outputRatio = Float(outWidth) / Float(outHeight)
        let maxCropW = stabHeight * outputRatio
        let maxCropH = stabHeight
        return (stabWidth / 2.0, stabHeight / 2.0, maxCropW, maxCropH)
    }
}
