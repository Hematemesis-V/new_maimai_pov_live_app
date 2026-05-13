import SwiftUI
import MetalKit

struct MetalView: UIViewRepresentable {
    let device: MTLDevice
    let texture: MTLTexture?

    func makeCoordinator() -> Coordinator {
        Coordinator(device: device)
    }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: device)
        view.delegate = context.coordinator
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        view.preferredFramesPerSecond = 60
        view.isPaused = false
        view.enableSetNeedsDisplay = false
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {
        context.coordinator.currentTexture = texture
    }

    class Coordinator: NSObject, MTKViewDelegate {
        private let device: MTLDevice
        private let commandQueue: MTLCommandQueue
        private var renderPipeline: MTLRenderPipelineState?
        var currentTexture: MTLTexture?

        init(device: MTLDevice) {
            self.device = device
            self.commandQueue = device.makeCommandQueue()!

            let library = device.makeDefaultLibrary()
            if let vf = library?.makeFunction(name: "vertex_main"),
               let ff = library?.makeFunction(name: "fragment_main") {
                let desc = MTLRenderPipelineDescriptor()
                desc.vertexFunction = vf
                desc.fragmentFunction = ff
                desc.colorAttachments[0].pixelFormat = .bgra8Unorm
                renderPipeline = try? device.makeRenderPipelineState(descriptor: desc)
            }
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            guard let drawable = view.currentDrawable,
                  let desc = view.currentRenderPassDescriptor,
                  let pipeline = renderPipeline,
                  let cmdBuf = commandQueue.makeCommandBuffer(),
                  let encoder = cmdBuf.makeRenderCommandEncoder(descriptor: desc) else { return }

            encoder.setRenderPipelineState(pipeline)
            encoder.setFragmentTexture(currentTexture, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
            encoder.endEncoding()
            cmdBuf.present(drawable)
            cmdBuf.commit()
        }
    }
}
