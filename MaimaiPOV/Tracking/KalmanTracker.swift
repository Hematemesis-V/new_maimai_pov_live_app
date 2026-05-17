import Foundation
import QuartzCore

class KalmanTracker {

    struct TrackOutput {
        var cx: Float
        var cy: Float
        var cropW: Float
        var cropH: Float
        var smoothCx: Float
        var smoothCy: Float
        var smoothW: Float
        var smoothH: Float
        var detected: Bool
        var state: String
    }

    private let n = 8
    private let m = 4

    private var x: [Float]
    private var P: [[Float]]
    private var F: [[Float]]
    private var H: [[Float]]
    private var Q: [[Float]]
    private var R: [[Float]]

    private var initialized = false
    private var lastUpdateTime: Double = 0
    private var lastDetectTime: Double = 0
    private var wasDetected = false

    var smoothness: Float = 0.5
    var responsiveness: Float = 0.5
    var targetRatio: Float = Float(Config.trackTargetRatio)

    var outputSmoothing: Float = 0.85

    private var outputEmaCx: Float?
    private var outputEmaCy: Float?
    private var outputEmaW: Float?
    private var outputEmaH: Float?

    private let maxPDiag: Float = 500.0

    var qPos: Float = 5.0
    var qVel: Float = 1.0
    var rPos: Float = 10.0
    var rSize: Float = 20.0

    var recenterGrace: Double = Config.defaultRecenterGrace
    var recenterDecay: Float = Config.defaultRecenterDecay

    private var predictedCx: Float = 0
    private var predictedCy: Float = 0
    private var predictedW: Float = 0
    private var predictedH: Float = 0
    private var velocityVx: Float = 0
    private var velocityVy: Float = 0
    private var velocityVw: Float = 0
    private var velocityVh: Float = 0

    init() {
        let stabW = Float(Config.stabWidth)
        let stabH = Float(Config.stabHeight)
        x = [stabW / 2.0, stabH / 2.0, stabH * (9.0 / 16.0), stabH, 0, 0, 0, 0]

        P = KalmanTracker.identity(n, value: 1000.0)

        F = KalmanTracker.identity(n, value: 1.0)

        H = Array(repeating: Array(repeating: Float(0), count: n), count: m)
        for i in 0..<m { H[i][i] = 1.0 }

        Q = KalmanTracker.identity(n, value: 1.0)
        R = KalmanTracker.identity(m, value: 10.0)

        updateNoiseFromIntuitiveParams()
    }

    func update(detected: Bool, stabCx: Float, stabCy: Float, stabW: Float, stabH: Float, dt: Double) -> TrackOutput {
        let now = CACurrentMediaTime()
        let stabWidth = Float(Config.stabWidth)
        let stabHeight = Float(Config.stabHeight)
        let outputRatio: Float = 9.0 / 16.0

        let effectiveDt: Float
        if lastUpdateTime > 0 {
            effectiveDt = Float(min(now - lastUpdateTime, 0.1))
        } else {
            effectiveDt = 1.0 / 60.0
        }
        lastUpdateTime = now

        updateF(dt: effectiveDt)

        if detected {
            if !initialized {
                x = [stabCx, stabCy, stabW, stabH, 0, 0, 0, 0]
                P = KalmanTracker.identity(n, value: 500.0)
                P[4][4] = 1000.0
                P[5][5] = 1000.0
                P[6][6] = 1000.0
                P[7][7] = 1000.0
                initialized = true
            } else {
                predict()
                updateWithMeasurement(z: [stabCx, stabCy, stabW, stabH])
            }
            lastDetectTime = now
            wasDetected = true
        } else if wasDetected {
            let elapsed = now - lastDetectTime
            if elapsed > recenterGrace {
                applyVelocityDamping(damping: 0.85)
            }

            predict()

            if elapsed > recenterGrace * 3 {
                let targetCx = stabWidth / 2.0
                let targetCy = stabHeight / 2.0
                let maxCropH = stabHeight
                let targetW = maxCropH * outputRatio
                let targetH = maxCropH

                let recenterStrength: Float = 0.02
                x[0] += (targetCx - x[0]) * recenterStrength
                x[1] += (targetCy - x[1]) * recenterStrength
                x[2] += (targetW - x[2]) * recenterStrength
                x[3] += (targetH - x[3]) * recenterStrength
                x[4] *= 0.9
                x[5] *= 0.9
                x[6] *= 0.9
                x[7] *= 0.9
            }
        }

        predictedCx = x[0]
        predictedCy = x[1]
        predictedW = x[2]
        predictedH = x[3]
        velocityVx = x[4]
        velocityVy = x[5]
        velocityVw = x[6]
        velocityVh = x[7]

        let smoothCx = x[0]
        let smoothCy = x[1]
        let smoothW = x[2]
        let smoothH = x[3]

        let baseH = max(smoothH, smoothW / outputRatio)
        let desiredCropH = baseH * (1.0 + targetRatio)
        let maxCropH = stabHeight
        let cropH = min(desiredCropH, maxCropH)
        let cropW = cropH * outputRatio

        let state: String
        if detected {
            state = "tracking"
        } else if wasDetected {
            let elapsed = now - lastDetectTime
            if elapsed <= recenterGrace {
                state = "coasting"
            } else if elapsed <= recenterGrace * 5 {
                state = "coasting"
            } else {
                state = "recenter"
            }
        } else {
            state = "idle"
        }

        return applyOutputSmoothing(TrackOutput(
            cx: smoothCx,
            cy: smoothCy,
            cropW: cropW,
            cropH: cropH,
            smoothCx: smoothCx,
            smoothCy: smoothCy,
            smoothW: smoothW,
            smoothH: smoothH,
            detected: detected,
            state: state
        ))
    }

    func predictOnly() -> TrackOutput {
        let now = CACurrentMediaTime()
        let stabWidth = Float(Config.stabWidth)
        let stabHeight = Float(Config.stabHeight)
        let outputRatio: Float = 9.0 / 16.0

        let effectiveDt: Float
        if lastUpdateTime > 0 {
            effectiveDt = Float(min(now - lastUpdateTime, 0.1))
        } else {
            effectiveDt = 1.0 / 60.0
        }
        lastUpdateTime = now

        updateF(dt: effectiveDt)

        if wasDetected {
            let elapsed = now - lastDetectTime
            if elapsed > recenterGrace {
                applyVelocityDamping(damping: 0.85)
            }

            predict()

            if elapsed > recenterGrace * 3 {
                let targetCx = stabWidth / 2.0
                let targetCy = stabHeight / 2.0
                let maxCropH = stabHeight
                let targetW = maxCropH * outputRatio
                let targetH = maxCropH

                let recenterStrength: Float = 0.02
                x[0] += (targetCx - x[0]) * recenterStrength
                x[1] += (targetCy - x[1]) * recenterStrength
                x[2] += (targetW - x[2]) * recenterStrength
                x[3] += (targetH - x[3]) * recenterStrength
                x[4] *= 0.9
                x[5] *= 0.9
                x[6] *= 0.9
                x[7] *= 0.9
            }
        }

        predictedCx = x[0]
        predictedCy = x[1]
        predictedW = x[2]
        predictedH = x[3]
        velocityVx = x[4]
        velocityVy = x[5]
        velocityVw = x[6]
        velocityVh = x[7]

        let smoothCx = x[0]
        let smoothCy = x[1]
        let smoothW = x[2]
        let smoothH = x[3]

        let baseH = max(smoothH, smoothW / outputRatio)
        let desiredCropH = baseH * (1.0 + targetRatio)
        let maxCropH = stabHeight
        let cropH = min(desiredCropH, maxCropH)
        let cropW = cropH * outputRatio

        let state: String
        if wasDetected {
            let elapsed = now - lastDetectTime
            if elapsed <= recenterGrace {
                state = "coasting"
            } else if elapsed <= recenterGrace * 3 {
                state = "coasting"
            } else {
                state = "recenter"
            }
        } else {
            state = "idle"
        }

        return applyOutputSmoothing(TrackOutput(
            cx: smoothCx,
            cy: smoothCy,
            cropW: cropW,
            cropH: cropH,
            smoothCx: smoothCx,
            smoothCy: smoothCy,
            smoothW: smoothW,
            smoothH: smoothH,
            detected: false,
            state: state
        ))
    }

    func reset() {
        let stabW = Float(Config.stabWidth)
        let stabH = Float(Config.stabHeight)
        x = [stabW / 2.0, stabH / 2.0, stabH * (9.0 / 16.0), stabH, 0, 0, 0, 0]
        P = KalmanTracker.identity(n, value: 1000.0)
        initialized = false
        wasDetected = false
        lastDetectTime = 0
        lastUpdateTime = 0
        predictedCx = 0
        predictedCy = 0
        predictedW = 0
        predictedH = 0
        velocityVx = 0
        velocityVy = 0
        velocityVw = 0
        velocityVh = 0
        outputEmaCx = nil
        outputEmaCy = nil
        outputEmaW = nil
        outputEmaH = nil
    }

    func updateNoiseFromIntuitiveParams() {
        let qPosMapped = lerp(0.05, 80.0, responsiveness)
        let qVelMapped = lerp(0.001, 2.0, responsiveness)
        let rPosMapped = lerp(5.0, 200.0, smoothness)
        let rSizeMapped = lerp(10.0, 500.0, smoothness)

        qPos = qPosMapped
        qVel = qVelMapped
        rPos = rPosMapped
        rSize = rSizeMapped

        rebuildQ()
        rebuildR()
        boostP()
    }

    func updateNoiseFromAdvancedParams() {
        rebuildQ()
        rebuildR()
        boostP()
    }

    private func boostP() {
        for i in 0..<4 {
            P[i][i] = max(P[i][i], 100.0)
        }
        for i in 4..<8 {
            P[i][i] = max(P[i][i], 500.0)
        }
    }

    func getPredictedCx() -> Float { predictedCx }
    func getPredictedCy() -> Float { predictedCy }
    func getPredictedW() -> Float { predictedW }
    func getPredictedH() -> Float { predictedH }
    func getVelocityVx() -> Float { velocityVx }
    func getVelocityVy() -> Float { velocityVy }
    func getVelocityVw() -> Float { velocityVw }
    func getVelocityVh() -> Float { velocityVh }

    private func updateF(dt: Float) {
        F = KalmanTracker.identity(n, value: 1.0)
        F[0][4] = dt
        F[1][5] = dt
        F[2][6] = dt
        F[3][7] = dt
    }

    private func rebuildQ() {
        Q = Array(repeating: Array(repeating: Float(0), count: n), count: n)
        Q[0][0] = qPos
        Q[1][1] = qPos
        Q[2][2] = qPos
        Q[3][3] = qPos
        Q[4][4] = qVel
        Q[5][5] = qVel
        Q[6][6] = qVel
        Q[7][7] = qVel
    }

    private func rebuildR() {
        R = Array(repeating: Array(repeating: Float(0), count: m), count: m)
        R[0][0] = rPos
        R[1][1] = rPos
        R[2][2] = rSize
        R[3][3] = rSize
    }

    private func predict() {
        x = matVecMul(F, x)

        let FPt = matMul(F, P)
        P = matMul(FPt, transpose(F))
        P = matAdd(P, Q)

        for i in 0..<n {
            P[i][i] = min(P[i][i], maxPDiag)
        }

        symmetrize(&P)
    }

    private func updateWithMeasurement(z: [Float]) {
        updateWithMeasurementAndR(z: z, r: R)
    }

    private func updateWithMeasurementAndR(z: [Float], r: [[Float]]) {
        let y = vecSub(z, matVecMul(H, x))

        let Ht = transpose(H)
        let PHt = matMul(P, Ht)
        let S = matAdd(matMul(H, PHt), r)

        let Si = invert4x4(S)
        guard let Si = Si else { return }

        let K = matMul(PHt, Si)

        x = vecAdd(x, matVecMul(K, y))

        let KH = matMul(K, H)
        let I = KalmanTracker.identity(n, value: 1.0)
        let IKH = matSub(I, KH)
        P = matMul(IKH, P)

        symmetrize(&P)
    }

    private func applyVelocityDamping(damping: Float) {
        for i in 4..<8 {
            for j in 0..<n {
                P[i][j] *= (2.0 - damping)
                P[j][i] *= (2.0 - damping)
            }
        }
    }

    private func symmetrize(_ m: inout [[Float]]) {
        for i in 0..<m.count {
            for j in (i + 1)..<m[i].count {
                let avg = (m[i][j] + m[j][i]) / 2.0
                m[i][j] = avg
                m[j][i] = avg
            }
        }
    }

    private func lerp(_ a: Float, _ b: Float, _ t: Float) -> Float {
        return a + (b - a) * t
    }

    private static func identity(_ n: Int, value: Float) -> [[Float]] {
        var m = Array(repeating: Array(repeating: Float(0), count: n), count: n)
        for i in 0..<n { m[i][i] = value }
        return m
    }

    private func matMul(_ a: [[Float]], _ b: [[Float]]) -> [[Float]] {
        let rows = a.count
        let cols = b[0].count
        let inner = b.count
        var result = Array(repeating: Array(repeating: Float(0), count: cols), count: rows)
        for i in 0..<rows {
            for j in 0..<cols {
                var sum: Float = 0
                for k in 0..<inner {
                    sum += a[i][k] * b[k][j]
                }
                result[i][j] = sum
            }
        }
        return result
    }

    private func matVecMul(_ a: [[Float]], _ v: [Float]) -> [Float] {
        let rows = a.count
        var result = Array(repeating: Float(0), count: rows)
        for i in 0..<rows {
            var sum: Float = 0
            for j in 0..<a[i].count {
                sum += a[i][j] * v[j]
            }
            result[i] = sum
        }
        return result
    }

    private func matAdd(_ a: [[Float]], _ b: [[Float]]) -> [[Float]] {
        let rows = a.count
        let cols = a[0].count
        var result = Array(repeating: Array(repeating: Float(0), count: cols), count: rows)
        for i in 0..<rows {
            for j in 0..<cols {
                result[i][j] = a[i][j] + b[i][j]
            }
        }
        return result
    }

    private func matSub(_ a: [[Float]], _ b: [[Float]]) -> [[Float]] {
        let rows = a.count
        let cols = a[0].count
        var result = Array(repeating: Array(repeating: Float(0), count: cols), count: rows)
        for i in 0..<rows {
            for j in 0..<cols {
                result[i][j] = a[i][j] - b[i][j]
            }
        }
        return result
    }

    private func vecAdd(_ a: [Float], _ b: [Float]) -> [Float] {
        var result = a
        for i in 0..<a.count { result[i] += b[i] }
        return result
    }

    private func vecSub(_ a: [Float], _ b: [Float]) -> [Float] {
        var result = a
        for i in 0..<a.count { result[i] -= b[i] }
        return result
    }

    private func transpose(_ a: [[Float]]) -> [[Float]] {
        let rows = a.count
        let cols = a[0].count
        var result = Array(repeating: Array(repeating: Float(0), count: rows), count: cols)
        for i in 0..<rows {
            for j in 0..<cols {
                result[j][i] = a[i][j]
            }
        }
        return result
    }

    private func invert4x4(_ m: [[Float]]) -> [[Float]]? {
        guard m.count == 4, m[0].count == 4 else { return nil }

        var a = Array(repeating: Array(repeating: Float(0), count: 8), count: 4)
        for i in 0..<4 {
            for j in 0..<4 {
                a[i][j] = m[i][j]
            }
            a[i][i + 4] = 1.0
        }

        for col in 0..<4 {
            var maxRow = col
            var maxVal = abs(a[col][col])
            for row in (col + 1)..<4 {
                if abs(a[row][col]) > maxVal {
                    maxVal = abs(a[row][col])
                    maxRow = row
                }
            }
            if maxVal < 1e-10 { return nil }

            if maxRow != col {
                a.swapAt(col, maxRow)
            }

            let pivot = a[col][col]
            for j in 0..<8 {
                a[col][j] /= pivot
            }

            for row in 0..<4 {
                if row == col { continue }
                let factor = a[row][col]
                for j in 0..<8 {
                    a[row][j] -= factor * a[col][j]
                }
            }
        }

        var result = Array(repeating: Array(repeating: Float(0), count: 4), count: 4)
        for i in 0..<4 {
            for j in 0..<4 {
                result[i][j] = a[i][j + 4]
            }
        }
        return result
    }

    private func applyOutputSmoothing(_ output: TrackOutput) -> TrackOutput {
        let alpha = outputSmoothing
        var result = output

        if let prevCx = outputEmaCx, let prevCy = outputEmaCy,
           let prevCropW = outputEmaW, let prevCropH = outputEmaH {
            result.cx = alpha * output.cx + (1 - alpha) * prevCx
            result.cy = alpha * output.cy + (1 - alpha) * prevCy
            result.cropW = alpha * output.cropW + (1 - alpha) * prevCropW
            result.cropH = alpha * output.cropH + (1 - alpha) * prevCropH
        }

        outputEmaCx = result.cx
        outputEmaCy = result.cy
        outputEmaW = result.cropW
        outputEmaH = result.cropH

        return result
    }
}
