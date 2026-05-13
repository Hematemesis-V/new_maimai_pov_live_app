import Foundation

struct YOLOPreprocessUniforms {
    var padding: Float
    var scale: Float
    var padLeft: Float
    var padTop: Float
    var padRight: Float
    var padBottom: Float
    var stabWidth: Float
    var stabHeight: Float

    init() {
        let pad = Float(Config.yoloPadding)
        let yoloIn = Float(Config.yoloInputSize)
        let sw = Float(Config.stabWidth)
        let sh = Float(Config.stabHeight)

        let paddedW = sw + pad * 2
        let paddedH = sh + pad * 2

        scale = min(yoloIn / paddedW, yoloIn / paddedH)

        let newW = Int(paddedW * scale)
        let newH = Int(paddedH * scale)

        let pl = (Config.yoloInputSize - newW) / 2
        let pt = (Config.yoloInputSize - newH) / 2
        let pr = Config.yoloInputSize - newW - pl
        let pb = Config.yoloInputSize - newH - pt

        padding = pad
        padLeft = Float(pl)
        padTop = Float(pt)
        padRight = Float(pr)
        padBottom = Float(pb)
        stabWidth = sw
        stabHeight = sh
    }
}
