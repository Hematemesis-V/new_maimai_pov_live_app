struct LensConfig {
    let name: String
    var fx: Float
    var fy: Float
    var cx: Float
    var cy: Float
    let k1: Float
    let k2: Float
    let k3: Float
    let k4: Float
    let defaultFov: Float
}

enum LensCalibration {
    static let calibBaseWidth: Float = 1440.0

    static let main = LensConfig(
        name: "Main (Full Frame)",
        fx: 637.96525775, fy: 637.53280269,
        cx: 720.0, cy: 960.0,
        k1: 0.14130226, k2: -0.07536199,
        k3: 0.02657343, k4: -0.00507701,
        defaultFov: 100
    )

    static let ultraWide = LensConfig(
        name: "Ultra-Wide (Circular)",
        fx: 375.5078, fy: 375.7163,
        cx: 715.9977, cy: 955.2196,
        k1: 0.047681, k2: 0.005396,
        k3: -0.006743, k4: 0.000068,
        defaultFov: 145
    )

    static func config(for lens: LensType, inputWidth: Int) -> LensConfig {
        let scale = Float(inputWidth) / calibBaseWidth
        var config = (lens == .main) ? main : ultraWide
        config.fx *= scale
        config.fy *= scale
        config.cx *= scale
        config.cy *= scale
        return config
    }
}
