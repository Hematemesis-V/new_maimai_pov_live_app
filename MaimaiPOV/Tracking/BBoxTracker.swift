import Foundation

class BBoxTracker {

    struct TrackOutput {
        var cx: Float
        var cy: Float
        var cropW: Float
        var cropH: Float
        var detected: Bool
        var state: String
        var rawW: Float = 0
        var rawH: Float = 0
        var smoothSize: Float = 0
        var trust: Float = 1.0
        var aspectRatio: Float = 1.0
    }

    var targetRatio: Float = Float(Config.trackTargetRatio)
    var recenterSpeed: Float = Float(Config.defaultRecenterSpeed)

    var smoothingEnabled: Bool = Config.smoothingEnabled
    var smoothingBaseAlpha: Float = Float(Config.smoothingBaseAlpha)
    var smoothingMinDeviation: Float = Float(Config.smoothingMinDeviation)
    var smoothingMaxDeviation: Float = Float(Config.smoothingMaxDeviation)
    var smoothingCenterFloor: Float = Float(Config.smoothingCenterFloor)

    private let stabWidth = Float(Config.stabWidth)
    private let stabHeight = Float(Config.stabHeight)
    private let outputRatio: Float = 9.0 / 16.0

    private var lastCx: Float
    private var lastCy: Float
    private var lastCropW: Float
    private var lastCropH: Float
    private var wasDetected: Bool = false
    private var currentState: String = "idle"

    private var smoothCx: Float = 0
    private var smoothCy: Float = 0
    private var smoothSize: Float = 0
    private var smoothInitialized: Bool = false

    private var lastTrust: Float = 1.0
    private var lastAspectRatio: Float = 1.0
    private var lastRawW: Float = 0
    private var lastRawH: Float = 0
    private var lastSmoothSize: Float = 0

    init() {
        lastCx = stabWidth / 2.0
        lastCy = stabHeight / 2.0
        lastCropW = stabHeight * outputRatio
        lastCropH = stabHeight
    }

    func update(detected: Bool, stabCx: Float, stabCy: Float, stabW: Float, stabH: Float) -> TrackOutput {
        if detected {
            let rawSize = (stabW + stabH) / 2.0
            let ratio = stabW / max(stabH, 0.001)
            lastAspectRatio = ratio
            lastRawW = stabW
            lastRawH = stabH

            if !smoothInitialized {
                smoothCx = stabCx
                smoothCy = stabCy
                smoothSize = rawSize
                smoothInitialized = true
                lastTrust = 1.0
            } else if smoothingEnabled {
                let deviation = abs(ratio - 1.0)
                let range = smoothingMaxDeviation - smoothingMinDeviation
                let trust = range > 0
                    ? max(0.0, min(1.0, 1.0 - (deviation - smoothingMinDeviation) / range))
                    : (deviation <= smoothingMinDeviation ? 1.0 : 0.0)
                lastTrust = trust

                let alphaSize = smoothingBaseAlpha * trust
                let alphaCenter = smoothingBaseAlpha * (smoothingCenterFloor + (1.0 - smoothingCenterFloor) * trust)

                smoothCx = alphaCenter * stabCx + (1.0 - alphaCenter) * smoothCx
                smoothCy = alphaCenter * stabCy + (1.0 - alphaCenter) * smoothCy
                smoothSize = alphaSize * rawSize + (1.0 - alphaSize) * smoothSize
            } else {
                smoothCx = stabCx
                smoothCy = stabCy
                smoothSize = rawSize
                lastTrust = 1.0
            }

            lastSmoothSize = smoothSize

            let baseH = max(smoothSize, smoothSize / outputRatio)
            let desiredCropH = baseH * (1.0 + targetRatio)
            let cropH = desiredCropH
            let cropW = cropH * outputRatio

            lastCx = smoothCx
            lastCy = smoothCy
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
                state: currentState,
                rawW: stabW,
                rawH: stabH,
                smoothSize: smoothSize,
                trust: lastTrust,
                aspectRatio: ratio
            )
        } else if wasDetected {
            smoothInitialized = false

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
                state: currentState,
                rawW: lastRawW,
                rawH: lastRawH,
                smoothSize: lastSmoothSize,
                trust: lastTrust,
                aspectRatio: lastAspectRatio
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
            state: currentState,
            rawW: lastRawW,
            rawH: lastRawH,
            smoothSize: lastSmoothSize,
            trust: lastTrust,
            aspectRatio: lastAspectRatio
        )
    }

    func reset() {
        lastCx = stabWidth / 2.0
        lastCy = stabHeight / 2.0
        lastCropW = stabHeight * outputRatio
        lastCropH = stabHeight
        wasDetected = false
        currentState = "idle"
        smoothInitialized = false
    }
}
