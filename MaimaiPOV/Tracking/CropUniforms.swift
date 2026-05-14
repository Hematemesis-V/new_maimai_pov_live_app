import Foundation

struct CropUniforms {
    var cropX1: Float = 0
    var cropY1: Float = 0
    var cropW: Float = 0
    var cropH: Float = 0
    var stabWidth: Float = Float(Config.stabWidth)
    var stabHeight: Float = Float(Config.stabHeight)
    var outWidth: Float = Float(Config.outputWidth)
    var outHeight: Float = Float(Config.outputHeight)
}
