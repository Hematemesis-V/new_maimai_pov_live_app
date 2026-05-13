import simd

struct StabilizerUniforms {
    var inputWidth: Float
    var inputHeight: Float
    var outputWidth: Float
    var outputHeight: Float

    var qCenter: simd_float4
    var qTop: simd_float4
    var qBottom: simd_float4
    var qAnchor: simd_float4

    var fovRadHalf: Float
    var distRatio: Float
    var useRollingShutter: UInt32

    var R_view: simd_float4x4

    var fx: Float
    var fy: Float
    var cx: Float
    var cy: Float
    var k1: Float
    var k2: Float
    var k3: Float
    var k4: Float

    var calibWidth: Float
    var calibHeight: Float

    init() {
        inputWidth = 1440
        inputHeight = 1920
        outputWidth = 1080
        outputHeight = 1440
        qCenter = simd_float4(0, 0, 0, 1)
        qTop = simd_float4(0, 0, 0, 1)
        qBottom = simd_float4(0, 0, 0, 1)
        qAnchor = simd_float4(0, 0, 0, 1)
        fovRadHalf = 100.0 * .pi / 360.0
        distRatio = 0
        useRollingShutter = 0
        R_view = matrix_identity_float4x4
        fx = 637.965; fy = 637.533
        cx = 720; cy = 960
        k1 = 0.1413; k2 = -0.07536; k3 = 0.02657; k4 = -0.005077
        calibWidth = 1440.0
        calibHeight = 1920.0
    }

    static func quatToFloat4(_ q: simd_quatf) -> simd_float4 {
        simd_float4(q.vector.x, q.vector.y, q.vector.z, q.vector.w)
    }
}
