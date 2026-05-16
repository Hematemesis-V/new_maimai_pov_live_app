import SwiftUI
import Metal
import CoreImage

struct YOLOOverlayView: View {
    @ObservedObject var debug: DebugInfoManager
    let device: MTLDevice
    let texture: MTLTexture?
    
    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if let tex = texture {
                    MetalView(device: device, texture: tex, previewEnabled: true)
                        .aspectRatio(contentMode: .fit)
                        .overlay(
                            Canvas { context, size in
                                drawBoundingBox(context: context, size: size, textureSize: tex.size)
                            }
                        )
                } else {
                    Rectangle()
                        .fill(Color.black)
                        .overlay(Text("No Preview").foregroundColor(.gray))
                }
            }
            .scaleEffect(scale * CGFloat(debug.yoloOverlayScale))
            .offset(offset)
            .gesture(
                MagnificationGesture()
                    .onChanged { value in
                        let delta = value / lastScale
                        scale *= delta
                        lastScale = value
                    }
                    .onEnded { _ in
                        lastScale = 1.0
                    }
            )
            .simultaneousGesture(
                DragGesture()
                    .onChanged { value in
                        offset = CGSize(
                            width: lastOffset.width + value.translation.width,
                            height: lastOffset.height + value.translation.height
                        )
                    }
                    .onEnded { _ in
                        lastOffset = offset
                    }
            )
        }
        .border(Color.cyan, width: 1)
        .cornerRadius(4)
    }
    
    private func drawBoundingBox(context: GraphicsContext, size: CGSize, textureSize: MTLSize) {
        guard debug.yoloDetected else { return }
        
        let stabWidth = Float(Config.stabWidth)
        let stabHeight = Float(Config.stabHeight)
        
        let cx = debug.yoloStabCx
        let cy = debug.yoloStabCy
        let w = debug.yoloStabW
        let h = debug.yoloStabH
        
        let halfW = w / 2.0
        let halfH = h / 2.0
        
        let x1 = cx - halfW
        let y1 = cy - halfH
        let x2 = cx + halfW
        let y2 = cy + halfH
        
        let scaleX = size.width / CGFloat(stabWidth)
        let scaleY = size.height / CGFloat(stabHeight)
        
        let rect = CGRect(
            x: CGFloat(x1) * scaleX,
            y: CGFloat(y1) * scaleY,
            width: CGFloat(w) * scaleX,
            height: CGFloat(h) * scaleY
        )
        
        context.stroke(
            Path(rect),
            with: .color(.cyan),
            lineWidth: 3
        )
        
        let conf = String(format: "%.2f", debug.yoloConfidence)
        context.draw(
            Text(conf).font(.system(size: 10, weight: .bold)).foregroundColor(.white),
            at: CGPoint(x: rect.minX + 5, y: rect.minY - 12)
        )
    }
}

private extension MTLTexture {
    var size: MTLSize {
        MTLSize(width: width, height: height, depth: depth)
    }
}
