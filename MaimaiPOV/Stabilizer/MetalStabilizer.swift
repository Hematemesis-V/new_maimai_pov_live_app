import Metal
import CoreVideo
import simd

class MetalStabilizer {

    let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLComputePipelineState
    private let uniformsBuffer: MTLBuffer
    private var uniforms: StabilizerUniforms

    private var textureCache: CVMetalTextureCache
    private(set) var outputTexture: MTLTexture

    private let gpuEvent: MTLEvent
    private var eventValue: UInt64 = 0

    private var readbackBuffer: MTLBuffer?
    private var readbackTexture: MTLTexture?

    var anchorQuaternion: simd_quatf?
    var lensConfig: LensConfig

    var fov: Float {
        get { uniforms.fovRadHalf * 360.0 / .pi }
        set { uniforms.fovRadHalf = newValue * .pi / 360.0 }
    }
    var distRatio: Float {
        get { uniforms.distRatio }
        set { uniforms.distRatio = simd_clamp(newValue, 0, 1) }
    }
    var useRollingShutter: Bool {
        get { uniforms.useRollingShutter != 0 }
        set { uniforms.useRollingShutter = newValue ? 1 : 0 }
    }
    var yaw: Float = 0
    var pitch: Float = 0
    var roll: Float = 0
    var stabilizerEnabled: Bool = true

    init?(device: MTLDevice, lensConfig: LensConfig) {
        self.device = device
        self.lensConfig = lensConfig

        guard let queue = device.makeCommandQueue() else { return nil }
        self.commandQueue = queue

        guard let library = device.makeDefaultLibrary(),
              let kernel = library.makeFunction(name: "stabilize"),
              let ps = try? device.makeComputePipelineState(function: kernel) else {
            print("MetalStabilizer: cannot compile shader")
            return nil
        }
        self.pipelineState = ps

        self.uniforms = StabilizerUniforms()
        self.uniformsBuffer = device.makeBuffer(
            length: MemoryLayout<StabilizerUniforms>.stride,
            options: .storageModeShared
        )!

        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        guard let texCache = cache else { return nil }
        self.textureCache = texCache

        let texDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: Int(uniforms.outputWidth),
            height: Int(uniforms.outputHeight),
            mipmapped: false
        )
        texDesc.usage = [.shaderWrite, .shaderRead]
        texDesc.storageMode = .private
        guard let outTex = device.makeTexture(descriptor: texDesc) else { return nil }
        self.outputTexture = outTex

        guard let event = device.makeEvent() else { return nil }
        self.gpuEvent = event

        setupReadbackResources()

        loadLensConfig(lensConfig)
    }

    func loadLensConfig(_ config: LensConfig) {
        self.lensConfig = config
        uniforms.fx = config.fx
        uniforms.fy = config.fy
        uniforms.cx = config.cx
        uniforms.cy = config.cy
        uniforms.k1 = config.k1
        uniforms.k2 = config.k2
        uniforms.k3 = config.k3
        uniforms.k4 = config.k4
        uniforms.calibWidth = 1440.0
        uniforms.calibHeight = 1920.0
    }

    func setAnchor(_ q: simd_quatf) {
        anchorQuaternion = q
        uniforms.qAnchor = StabilizerUniforms.quatToFloat4(q)
    }

    /// Build R_view = Rz(roll) * Ry(yaw) * Rx(pitch), matching Python ZeroCopyStabilizer
    private func buildViewRotationMatrix(yaw: Float, pitch: Float, roll: Float) -> simd_float4x4 {
        let cy = cos(yaw), sy = sin(yaw)
        let cp = cos(pitch), sp = sin(pitch)
        let cr = cos(roll), sr = sin(roll)

        var m = matrix_identity_float4x4
        // Column 0: R * [1,0,0]^T
        m.columns.0 = simd_float4(cr * cy, sr * cy, -sy, 0)
        // Column 1: R * [0,1,0]^T
        m.columns.1 = simd_float4(
            -sr * cp + cr * sy * sp,
             cr * cp + sr * sy * sp,
             cy * sp,
            0
        )
        // Column 2: R * [0,0,1]^T
        m.columns.2 = simd_float4(
             sr * sp + cr * sy * cp,
            -cr * sp + sr * sy * cp,
             cy * cp,
            0
        )
        return m
    }

    private static let devToCam = simd_quatf(ix: 1, iy: 0, iz: 0, r: 0)
    private static let devToCamInv = simd_quatf(ix: -1, iy: 0, iz: 0, r: 0)

    static func alignIMU(_ q: simd_quatf) -> simd_quatf {
        return devToCam * q * devToCamInv
    }

    func process(
        pixelBuffer: CVPixelBuffer,
        qCenter: simd_quatf,
        qTop: simd_quatf,
        qBottom: simd_quatf
    ) {
        guard stabilizerEnabled else { return }

        let qc = Self.alignIMU(qCenter)
        let qt = Self.alignIMU(qTop)
        let qb = Self.alignIMU(qBottom)

        if anchorQuaternion == nil {
            setAnchor(qc)
        }

        uniforms.qCenter = StabilizerUniforms.quatToFloat4(qc)
        uniforms.qTop    = StabilizerUniforms.quatToFloat4(qt)
        uniforms.qBottom = StabilizerUniforms.quatToFloat4(qb)
        uniforms.R_view  = buildViewRotationMatrix(yaw: yaw, pitch: pitch, roll: roll)

        let inW = CVPixelBufferGetWidth(pixelBuffer)
        let inH = CVPixelBufferGetHeight(pixelBuffer)
        uniforms.inputWidth  = Float(inW)
        uniforms.inputHeight = Float(inH)

        guard let yTexture = metalTexture(from: pixelBuffer, planeIndex: 0, format: .r8Unorm),
              let cbcrTexture = metalTexture(from: pixelBuffer, planeIndex: 1, format: .rg8Unorm) else {
            return
        }

        memcpy(uniformsBuffer.contents(), &uniforms, MemoryLayout<StabilizerUniforms>.stride)

        guard let cmdBuf = commandQueue.makeCommandBuffer(),
              let encoder = cmdBuf.makeComputeCommandEncoder() else { return }

        encoder.setComputePipelineState(pipelineState)
        encoder.setTexture(yTexture, index: 0)
        encoder.setTexture(cbcrTexture, index: 1)
        encoder.setTexture(outputTexture, index: 2)
        encoder.setBuffer(uniformsBuffer, offset: 0, index: 0)

        let tgSize = MTLSize(width: 16, height: 16, depth: 1)
        let gridSize = MTLSize(
            width: Int(uniforms.outputWidth),
            height: Int(uniforms.outputHeight),
            depth: 1
        )
        encoder.dispatchThreads(gridSize, threadsPerThreadgroup: tgSize)
        encoder.endEncoding()

        eventValue &+= 1
        cmdBuf.encodeSignalEvent(gpuEvent, value: eventValue)
        cmdBuf.commit()
    }

    func waitForCompletion() {
        gpuEvent.waitUntilSignaled(value: eventValue)
    }

    var lastSignaledValue: UInt64 {
        eventValue
    }

    // MARK: - Texture Readback

    private func setupReadbackResources() {
        let w = Int(uniforms.outputWidth)
        let h = Int(uniforms.outputHeight)
        let rowBytes = w * 4
        let bufferSize = rowBytes * h

        guard let buffer = device.makeBuffer(length: bufferSize, options: .storageModeShared) else { return }
        readbackBuffer = buffer

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: w,
            height: h,
            mipmapped: false
        )
        desc.usage = .shaderRead
        desc.storageMode = .shared

        guard let tex = buffer.makeTexture(
            descriptor: desc,
            offset: 0,
            bytesPerRow: rowBytes
        ) else { return }
        readbackTexture = tex
    }

    func readOutputTexture() -> CVPixelBuffer? {
        guard let readbackTex = readbackTexture,
              let cmdBuf = commandQueue.makeCommandBuffer(),
              let blitEncoder = cmdBuf.makeBlitCommandEncoder() else { return nil }

        blitEncoder.copy(
            from: outputTexture,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: outputTexture.width, height: outputTexture.height, depth: 1),
            to: readbackTex,
            destinationSlice: 0,
            destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
        )
        blitEncoder.endEncoding()

        let signalValue = eventValue &+ 1
        cmdBuf.encodeSignalEvent(gpuEvent, value: signalValue)
        cmdBuf.commit()
        gpuEvent.waitUntilSignaled(value: signalValue)

        let w = Int(uniforms.outputWidth)
        let h = Int(uniforms.outputHeight)

        var pixelBuffer: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]
        ]
        CVPixelBufferCreate(
            kCFAllocatorDefault,
            w, h,
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &pixelBuffer
        )

        guard let pb = pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }

        guard let dstBase = CVPixelBufferGetBaseAddress(pb) else { return nil }
        let dstRowBytes = CVPixelBufferGetBytesPerRow(pb)
        let srcRowBytes = w * 4

        guard let srcBase = readbackBuffer?.contents() else { return nil }

        if dstRowBytes == srcRowBytes {
            memcpy(dstBase, srcBase, srcRowBytes * h)
        } else {
            var srcPtr = srcBase
            var dstPtr = dstBase
            for _ in 0..<h {
                memcpy(dstPtr, srcPtr, srcRowBytes)
                srcPtr = srcPtr.advanced(by: srcRowBytes)
                dstPtr = dstPtr.advanced(by: dstRowBytes)
            }
        }

        return pb
    }

    // MARK: - Zero-copy bridge

    private func metalTexture(
        from pixelBuffer: CVPixelBuffer,
        planeIndex: Int,
        format: MTLPixelFormat
    ) -> MTLTexture? {
        let width  = planeIndex == 0
            ? CVPixelBufferGetWidth(pixelBuffer)
            : CVPixelBufferGetWidthOfPlane(pixelBuffer, planeIndex)
        let height = planeIndex == 0
            ? CVPixelBufferGetHeight(pixelBuffer)
            : CVPixelBufferGetHeightOfPlane(pixelBuffer, planeIndex)

        var cvTexture: CVMetalTexture?
        let ret = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, pixelBuffer, nil,
            format, width, height, planeIndex, &cvTexture
        )
        guard ret == kCVReturnSuccess, let cvTex = cvTexture else { return nil }
        return CVMetalTextureGetTexture(cvTex)
    }
}
