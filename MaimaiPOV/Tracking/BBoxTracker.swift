import Foundation

class BBoxTracker {

    struct TrackOutput {
        var cx: Float
        var cy: Float
        var cropW: Float
        var cropH: Float
        var detected: Bool
        var state: String
    }

    var targetRatio: Float = Float(Config.trackTargetRatio)
    var recenterSpeed: Float = Float(Config.defaultRecenterSpeed)

    private let stabWidth = Float(Config.stabWidth)
    private let stabHeight = Float(Config.stabHeight)
    private let outputRatio: Float = 9.0 / 16.0

    private var lastCx: Float
    private var lastCy: Float
    private var lastCropW: Float
    private var lastCropH: Float
    private var wasDetected: Bool = false
    private var currentState: String = "idle"

    init() {
        lastCx = stabWidth / 2.0
        lastCy = stabHeight / 2.0
        lastCropW = stabHeight * outputRatio
        lastCropH = stabHeight
    }

    func update(detected: Bool, stabCx: Float, stabCy: Float, stabW: Float, stabH: Float) -> TrackOutput {
        if detected {
            let baseH = max(stabH, stabW / outputRatio)
            let desiredCropH = baseH * (1.0 + targetRatio)
            let cropH = desiredCropH
            let cropW = cropH * outputRatio

            lastCx = stabCx
            lastCy = stabCy
            lastCropW = cropW
            lastCropH = cropH
            wasDetected = true
            currentState = "tracking"

            return TrackOutput(
                cx: lastCx,
                cy: lastCy,
                cropW: lastCropW,
                cropH: lastCropH,
                detected: true,
                state: currentState
            )
        } else if wasDetected {
            let centerCx = stabWidth / 2.0
            let centerCy = stabHeight / 2.0
            let fullCropH = stabHeight
            let fullCropW = stabHeight * outputRatio

            lastCx += (centerCx - lastCx) * recenterSpeed
            lastCy += (centerCy - lastCy) * recenterSpeed
            lastCropW += (fullCropW - lastCropW) * recenterSpeed
            lastCropH += (fullCropH - lastCropH) * recenterSpeed
            currentState = "recenter"

            return TrackOutput(
                cx: lastCx,
                cy: lastCy,
                cropW: lastCropW,
                cropH: lastCropH,
                detected: false,
                state: currentState
            )
        } else {
            currentState = "idle"
            return TrackOutput(
                cx: stabWidth / 2.0,
                cy: stabHeight / 2.0,
                cropW: stabHeight * outputRatio,
                cropH: stabHeight,
                detected: false,
                state: currentState
            )
        }
    }

    func freeze() -> TrackOutput {
        return TrackOutput(
            cx: lastCx,
            cy: lastCy,
            cropW: lastCropW,
            cropH: lastCropH,
            detected: wasDetected,
            state: currentState
        )
    }

    func reset() {
        lastCx = stabWidth / 2.0
        lastCy = stabHeight / 2.0
        lastCropW = stabHeight * outputRatio
        lastCropH = stabHeight
        wasDetected = false
        currentState = "idle"
    }
}
