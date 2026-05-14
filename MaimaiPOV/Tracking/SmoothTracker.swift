import Foundation
import QuartzCore

class SmoothTracker {

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

    private var smoothCx: Float = Float(Config.stabWidth) / 2.0
    private var smoothCy: Float = Float(Config.stabHeight) / 2.0
    private var smoothW: Float = 0
    private var smoothH: Float = 0
    private var initialized = false

    private var lastDetectTime: TimeInterval = 0
    private var wasDetected = false

    var alpha: Float = Config.defaultAlpha
    var maxSpeed: Float = Config.defaultMaxSpeed
    var deadZone: Float = Config.defaultDeadZone
    var targetRatio: Float = Config.defaultTargetRatio
    var recenterDecay: Float = Config.defaultRecenterDecay
    var recenterGrace: Double = Config.defaultRecenterGrace

    func update(detected: Bool, stabCx: Float, stabCy: Float, stabW: Float, stabH: Float) -> TrackOutput {
        let now = CACurrentMediaTime()
        let stabWidth = Float(Config.stabWidth)
        let stabHeight = Float(Config.stabHeight)
        let outputRatio: Float = 9.0 / 16.0

        if detected {
            if !initialized {
                smoothCx = stabCx
                smoothCy = stabCy
                smoothW = stabW
                smoothH = stabH
                initialized = true
            } else {
                let centerDist = hypot(stabCx - smoothCx, stabCy - smoothCy)

                var dx: Float = 0, dy: Float = 0, dw: Float = 0, dh: Float = 0
                if centerDist > deadZone {
                    dx = min(max(stabCx - smoothCx, -maxSpeed), maxSpeed)
                    dy = min(max(stabCy - smoothCy, -maxSpeed), maxSpeed)
                    dw = min(max(stabW - smoothW, -maxSpeed), maxSpeed)
                    dh = min(max(stabH - smoothH, -maxSpeed), maxSpeed)
                }

                let safeCx = smoothCx + dx
                let safeCy = smoothCy + dy
                let safeW = smoothW + dw
                let safeH = smoothH + dh

                smoothCx = alpha * safeCx + (1.0 - alpha) * smoothCx
                smoothCy = alpha * safeCy + (1.0 - alpha) * smoothCy
                smoothW = alpha * safeW + (1.0 - alpha) * smoothW
                smoothH = alpha * safeH + (1.0 - alpha) * smoothH
            }

            lastDetectTime = now
            wasDetected = true
        } else if wasDetected {
            let elapsed = now - lastDetectTime
            if elapsed > recenterGrace {
                let targetCx = stabWidth / 2.0
                let targetCy = stabHeight / 2.0
                smoothCx += (targetCx - smoothCx) * recenterDecay
                smoothCy += (targetCy - smoothCy) * recenterDecay

                let maxCropH = stabHeight
                smoothH += (maxCropH - smoothH) * recenterDecay
                smoothW += (maxCropH * outputRatio - smoothW) * recenterDecay
            }
        }

        let baseH = max(smoothH, smoothW / outputRatio)
        let cropH = baseH / targetRatio
        let cropW = cropH * outputRatio

        let state: String
        if detected {
            state = "tracking"
        } else if wasDetected {
            let elapsed = now - lastDetectTime
            state = elapsed > recenterGrace ? "recenter" : "grace"
        } else {
            state = "idle"
        }

        return TrackOutput(
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
        )
    }

    func reset() {
        smoothCx = Float(Config.stabWidth) / 2.0
        smoothCy = Float(Config.stabHeight) / 2.0
        smoothW = 0
        smoothH = 0
        initialized = false
        wasDetected = false
        lastDetectTime = 0
    }
}
