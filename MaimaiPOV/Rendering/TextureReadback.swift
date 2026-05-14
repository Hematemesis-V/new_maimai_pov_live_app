import Metal
import CoreVideo

class TextureReadback {
    private let device: MTLDevice
    private let width: Int
    private let height: Int
    private let sourceFormat: MTLPixelFormat
    private let commandQueue: MTLCommandQueue
    private static let bufferCount = 3
    private var readbackBuffers: [MTLBuffer] = []
    private var readbackTextures: [MTLTexture] = []
    private var currentIndex: Int = 0
    private var pixelBufferPool: CVPixelBufferPool?

    init?(device: MTLDevice, width: Int, height: Int, sourceFormat: MTLPixelFormat = .bgra8Unorm) {
        self.device = device
        self.width = width
        self.height = height
        self.sourceFormat = sourceFormat
        guard let queue = device.makeCommandQueue() else { return nil }
        self.commandQueue = queue
        setupReadbackResources()
        setupPixelBufferPool()
        assert(sourceFormat == .bgra8Unorm, "Non-BGRA format triggers CPU channel swap which is slow at \(width)x\(height)")
    }

    private func setupReadbackResources() {
        let rowBytes = width * 4
        let bufferSize = rowBytes * height

        for _ in 0..<Self.bufferCount {
            guard let buffer = device.makeBuffer(length: bufferSize, options: .storageModeShared) else { return }
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: sourceFormat,
                width: width,
                height: height,
                mipmapped: false
            )
            desc.usage = .shaderRead
            desc.storageMode = .shared

            guard let tex = buffer.makeTexture(
                descriptor: desc,
                offset: 0,
                bytesPerRow: rowBytes
            ) else { return }
            readbackBuffers.append(buffer)
            readbackTextures.append(tex)
        }
    }

    private func setupPixelBufferPool() {
        let bufferAttrs: [String: Any] = [
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]
        ]
        let poolAttrs: [String: Any] = [
            kCVPixelBufferPoolMinimumBufferCountKey as String: 3
        ]
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            poolAttrs as CFDictionary,
            bufferAttrs as CFDictionary,
            &pool
        )
        self.pixelBufferPool = pool
    }

    @available(*, deprecated, message: "Use readAsync(from:completion:) instead")
    func read(from texture: MTLTexture) -> CVPixelBuffer? {
        let index = currentIndex
        currentIndex = (index + 1) % Self.bufferCount

        guard index < readbackTextures.count, index < readbackBuffers.count,
              let cmdBuf = commandQueue.makeCommandBuffer(),
              let blitEncoder = cmdBuf.makeBlitCommandEncoder() else { return nil }

        let readbackTex = readbackTextures[index]
        let readbackBuf = readbackBuffers[index]

        blitEncoder.copy(
            from: texture,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: texture.width, height: texture.height, depth: 1),
            to: readbackTex,
            destinationSlice: 0,
            destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
        )
        blitEncoder.endEncoding()

        cmdBuf.commit()
        cmdBuf.waitUntilCompleted()

        guard let pool = pixelBufferPool else { return nil }
        var pixelBuffer: CVPixelBuffer?
        let result = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer)
        guard result == kCVReturnSuccess, let pb = pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }

        guard let dstBase = CVPixelBufferGetBaseAddress(pb) else { return nil }
        let dstRowBytes = CVPixelBufferGetBytesPerRow(pb)
        let srcRowBytes = width * 4
        let srcBase = readbackBuf.contents()

        if sourceFormat == .bgra8Unorm {
            copyRows(dstBase: dstBase, dstRowBytes: dstRowBytes,
                     srcBase: srcBase, srcRowBytes: srcRowBytes)
        } else {
            copyRowsSwapRB(dstBase: dstBase, dstRowBytes: dstRowBytes,
                           srcBase: srcBase, srcRowBytes: srcRowBytes)
        }

        return pb
    }

    func readAsync(from texture: MTLTexture, completion: @escaping (CVPixelBuffer) -> Void) {
        let index = currentIndex
        currentIndex = (index + 1) % Self.bufferCount

        guard index < readbackTextures.count, index < readbackBuffers.count,
              let cmdBuf = commandQueue.makeCommandBuffer(),
              let blitEncoder = cmdBuf.makeBlitCommandEncoder() else { return }

        let readbackTex = readbackTextures[index]
        let readbackBuf = readbackBuffers[index]

        blitEncoder.copy(
            from: texture,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: texture.width, height: texture.height, depth: 1),
            to: readbackTex,
            destinationSlice: 0,
            destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
        )
        blitEncoder.endEncoding()

        let w = self.width, h = self.height, fmt = self.sourceFormat
        cmdBuf.addCompletedHandler { [weak self] _ in
            guard let self = self, let pool = self.pixelBufferPool else { return }
            var pixelBuffer: CVPixelBuffer?
            let result = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer)
            guard result == kCVReturnSuccess, let pb = pixelBuffer else { return }

            CVPixelBufferLockBaseAddress(pb, [])
            defer { CVPixelBufferUnlockBaseAddress(pb, []) }

            guard let dstBase = CVPixelBufferGetBaseAddress(pb) else { return }
            let dstRowBytes = CVPixelBufferGetBytesPerRow(pb)
            let srcRowBytes = w * 4
            let srcBase = readbackBuf.contents()

            if fmt == .bgra8Unorm {
                self.copyRows(dstBase: dstBase, dstRowBytes: dstRowBytes,
                              srcBase: srcBase, srcRowBytes: srcRowBytes)
            } else {
                self.copyRowsSwapRB(dstBase: dstBase, dstRowBytes: dstRowBytes,
                                    srcBase: srcBase, srcRowBytes: srcRowBytes)
            }
            completion(pb)
        }
        cmdBuf.commit()
    }

    private func copyRows(dstBase: UnsafeMutableRawPointer, dstRowBytes: Int,
                          srcBase: UnsafeMutableRawPointer, srcRowBytes: Int) {
        if dstRowBytes == srcRowBytes {
            memcpy(dstBase, srcBase, srcRowBytes * height)
        } else {
            var srcPtr = srcBase
            var dstPtr = dstBase
            for _ in 0..<height {
                memcpy(dstPtr, srcPtr, srcRowBytes)
                srcPtr = srcPtr.advanced(by: srcRowBytes)
                dstPtr = dstPtr.advanced(by: dstRowBytes)
            }
        }
    }

    private func copyRowsSwapRB(dstBase: UnsafeMutableRawPointer, dstRowBytes: Int,
                                srcBase: UnsafeMutableRawPointer, srcRowBytes: Int) {
        for y in 0..<height {
            let srcRow = srcBase.advanced(by: y * srcRowBytes).assumingMemoryBound(to: UInt8.self)
            let dstRow = dstBase.advanced(by: y * dstRowBytes).assumingMemoryBound(to: UInt8.self)
            for x in 0..<width {
                let si = x * 4
                let di = x * 4
                dstRow[di]     = srcRow[si + 2]
                dstRow[di + 1] = srcRow[si + 1]
                dstRow[di + 2] = srcRow[si]
                dstRow[di + 3] = srcRow[si + 3]
            }
        }
    }
}
