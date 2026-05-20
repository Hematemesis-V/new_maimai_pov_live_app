import Metal
import UIKit

class OverlayCompositor {
    let device: MTLDevice
    private let pipelineState: MTLComputePipelineState
    private let uniformsBuffer: MTLBuffer

    private(set) var overlayTexture: MTLTexture?
    var enabled: Bool = true
    var posX: Float = 0.5
    var posY: Float = 0.5
    var scale: Float = 0.2
    var opacity: Float = 1.0

    let outWidth = Config.outputWidth
    let outHeight = Config.outputHeight

    init?(device: MTLDevice) {
        self.device = device

        guard let library = device.makeDefaultLibrary(),
              let kernel = library.makeFunction(name: "overlayBlend"),
              let ps = try? device.makeComputePipelineState(function: kernel) else {
            return nil
        }
        self.pipelineState = ps

        self.uniformsBuffer = device.makeBuffer(
            length: MemoryLayout<OverlayUniforms>.stride,
            options: .storageModeShared
        )!

        createTestTexture()
    }

    private func createTestTexture() {
        let size = 100
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: size * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return }

        context.setFillColor(UIColor(red: 1.0, green: 0.2, blue: 0.2, alpha: 0.7).cgColor)
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))

        context.setFillColor(UIColor.white.cgColor)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 48, weight: .bold),
            .foregroundColor: UIColor.white,
            .paragraphStyle: paragraphStyle
        ]
        let str = "M" as NSString
        let strSize = str.size(withAttributes: attrs)
        let strRect = CGRect(
            x: (CGFloat(size) - strSize.width) / 2,
            y: (CGFloat(size) - strSize.height) / 2,
            width: strSize.width,
            height: strSize.height
        )
        str.draw(in: strRect, withAttributes: attrs)

        guard let cgImage = context.makeImage() else { return }
        loadTextureFromCGImage(cgImage)
    }

    private func loadTextureFromCGImage(_ cgImage: CGImage) {
        let width = cgImage.width
        let height = cgImage.height

        let texDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        texDesc.usage = .shaderRead
        texDesc.storageMode = .private

        guard let texture = device.makeTexture(descriptor: texDesc) else { return }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else { return }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        guard let pixelData = context.data else { return }
        texture.replace(
            region: MTLRegion(origin: .init(x: 0, y: 0, z: 0),
                              size: MTLSize(width: width, height: height, depth: 1)),
            mipmapLevel: 0,
            withBytes: pixelData,
            bytesPerRow: width * 4
        )

        self.overlayTexture = texture
    }

    func encode(into encoder: MTLComputeCommandEncoder, outputTexture: MTLTexture) {
        guard let overlayTex = overlayTexture else { return }

        var uniforms = OverlayUniforms()
        uniforms.posX = posX
        uniforms.posY = posY
        uniforms.scale = scale
        uniforms.opacity = opacity
        uniforms.overlayWidth = Float(overlayTex.width)
        uniforms.overlayHeight = Float(overlayTex.height)
        uniforms.outWidth = Float(outWidth)
        uniforms.outHeight = Float(outHeight)

        memcpy(uniformsBuffer.contents(), &uniforms, MemoryLayout<OverlayUniforms>.stride)

        encoder.setComputePipelineState(pipelineState)
        encoder.setTexture(outputTexture, index: 0)
        encoder.setTexture(overlayTex, index: 1)
        encoder.setBuffer(uniformsBuffer, offset: 0, index: 0)

        let tgSize = MTLSize(width: 16, height: 16, depth: 1)
        let gridSize = MTLSize(width: outWidth, height: outHeight, depth: 1)
        encoder.dispatchThreads(gridSize, threadsPerThreadgroup: tgSize)
    }
}
