import SwiftUI

@MainActor
class DebugInfoManager: ObservableObject {
    static let shared = DebugInfoManager()

    @Published var fps: Double = 0
    @Published var pipelineLagMs: Double = 0
    @Published var audioQueueDepth: Int = 0
    @Published var yoloLagMs: Double = 0
    @Published var frameCount: Int = 0

    @Published var fov: Float = 0
    @Published var distRatio: Float = 0
    @Published var stabEnabled: Bool = true
    @Published var lensType: String = "main"

    @Published var yoloDetected: Bool = false
    @Published var yoloConfidence: Float = 0
    @Published var yoloBbox: String = "--"
    @Published var yoloInferenceMs: Double = 0
    @Published var yoloPreprocessMs: Double = 0
    @Published var yoloPadding: Int = Config.defaultYoloPadding
    @Published var yoloRawCoord: String = "--"
    @Published var yoloStabCoord: String = "--"
    @Published var yoloUniforms: String = "--"
    @Published var yoloBoxesInfo: String = "--"
    @Published var yoloTopBoxes: String = "--"
    @Published var yoloBestRank: Int = 0
    @Published var yoloPreviewImage: UIImage?
    
    @Published var yoloStabCx: Float = 0
    @Published var yoloStabCy: Float = 0
    @Published var yoloStabW: Float = 0
    @Published var yoloStabH: Float = 0
    @Published var yoloOverlayEnabled: Bool = Config.defaultYoloOverlayEnabled
    @Published var yoloOverlayScale: Double = Config.defaultYoloOverlayScale
    @Published var yoloTargetFPS: Double = Config.defaultYoloTargetFPS
    @Published var yoloActualFPS: Double = 0

    @Published var trackCx: Float = 0
    @Published var trackCy: Float = 0
    @Published var trackCropW: Float = 0
    @Published var trackCropH: Float = 0
    @Published var trackSmoothCx: Float = 0
    @Published var trackSmoothCy: Float = 0
    @Published var trackSmoothW: Float = 0
    @Published var trackSmoothH: Float = 0
    @Published var trackState: String = "idle"
    @Published var trackSmoothness: Float = Float(Config.defaultSmoothness)
    @Published var trackResponsiveness: Float = Float(Config.defaultResponsiveness)
    @Published var trackTargetRatio: Float = Float(Config.defaultTargetRatio)
    @Published var kalmanVx: Float = 0
    @Published var kalmanVy: Float = 0
    @Published var kalmanVw: Float = 0
    @Published var kalmanVh: Float = 0

    @Published var logMessages: [String] = []
    @Published var streamInfo: String = "--"
    private let maxLogMessages = 30

    @Published var rtmpStatus: String = "Idle"
    @Published var rtmpBitrate: Int = 0
    @Published var rtmpFPS: Int = 0
    @Published var deviceTemperature: Double = 0.0
    @Published var streamingDuration: String = "--"

    private let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    func log(_ msg: String) {
        let timestamp = timeFormatter.string(from: Date())
        let entry = "[\(timestamp)] \(msg)"
        logMessages.append(entry)
        if logMessages.count > maxLogMessages {
            logMessages.removeFirst(logMessages.count - maxLogMessages)
        }
    }
}
