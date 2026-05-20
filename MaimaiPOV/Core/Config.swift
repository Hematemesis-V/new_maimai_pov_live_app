import Foundation

enum Config {
    // Resolution
    static let inputWidth  = 1440
    static let inputHeight = 1920
    static let stabWidth   = 1080
    static let stabHeight  = 1440
    static let yoloInputSize = 640
    static let defaultYoloPadding: Int = 40
    static var yoloPadding: Int {
        get {
            let v = UserDefaults.standard.integer(forKey: yoloPaddingKey)
            return v == 0 ? defaultYoloPadding : v
        }
        set { UserDefaults.standard.set(newValue, forKey: yoloPaddingKey) }
    }
    static let defaultYoloPreviewEnabled: Bool = false
    static var yoloPreviewEnabled: Bool {
        get {
            guard UserDefaults.standard.object(forKey: yoloPreviewEnabledKey) != nil else {
                return defaultYoloPreviewEnabled
            }
            return UserDefaults.standard.bool(forKey: yoloPreviewEnabledKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: yoloPreviewEnabledKey) }
    }
    static let defaultYoloOverlayEnabled: Bool = false
    static var yoloOverlayEnabled: Bool {
        get {
            guard UserDefaults.standard.object(forKey: yoloOverlayEnabledKey) != nil else {
                return defaultYoloOverlayEnabled
            }
            return UserDefaults.standard.bool(forKey: yoloOverlayEnabledKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: yoloOverlayEnabledKey) }
    }
    static let defaultYoloOverlayScale: Double = 0.6
    static var yoloOverlayScale: Double {
        get {
            guard UserDefaults.standard.object(forKey: yoloOverlayScaleKey) != nil else {
                return defaultYoloOverlayScale
            }
            return UserDefaults.standard.double(forKey: yoloOverlayScaleKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: yoloOverlayScaleKey) }
    }
    static let defaultYoloTargetFPS: Double = 20.0
    static var yoloTargetFPS: Double {
        get {
            guard UserDefaults.standard.object(forKey: yoloTargetFPSKey) != nil else {
                return defaultYoloTargetFPS
            }
            return UserDefaults.standard.double(forKey: yoloTargetFPSKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: yoloTargetFPSKey) }
    }
    static let outputWidth  = 720
    static let outputHeight = 1280

    // Camera settings
    static let defaultFocusValue: Double = 0.5
    static var focusValue: Double {
        get {
            guard UserDefaults.standard.object(forKey: focusValueKey) != nil else {
                return defaultFocusValue
            }
            return UserDefaults.standard.double(forKey: focusValueKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: focusValueKey) }
    }
    static let defaultShutterTimescale: Double = 244.0
    static var shutterTimescale: Double {
        get {
            guard UserDefaults.standard.object(forKey: shutterTimescaleKey) != nil else {
                return defaultShutterTimescale
            }
            return UserDefaults.standard.double(forKey: shutterTimescaleKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: shutterTimescaleKey) }
    }
    static let defaultIsoValue: Double = 2000.0
    static var isoValue: Double {
        get {
            guard UserDefaults.standard.object(forKey: isoValueKey) != nil else {
                return defaultIsoValue
            }
            return UserDefaults.standard.double(forKey: isoValueKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: isoValueKey) }
    }
    static let defaultSelectedLens: LensType = .main
    static var selectedLens: LensType {
        get {
            guard let rawValue = UserDefaults.standard.string(forKey: selectedLensKey),
                  let lens = LensType(rawValue: rawValue) else {
                return defaultSelectedLens
            }
            return lens
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: selectedLensKey) }
    }

    // Tracking defaults
    static let defaultTargetRatio: Float = 0.35
    static var trackTargetRatio: Double {
        get {
            guard UserDefaults.standard.object(forKey: trackTargetRatioKey) != nil else {
                return Double(defaultTargetRatio)
            }
            return UserDefaults.standard.double(forKey: trackTargetRatioKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: trackTargetRatioKey) }
    }
    static let defaultRecenterSpeed: Float = 0.15
    static var trackRecenterSpeed: Double {
        get {
            guard UserDefaults.standard.object(forKey: trackRecenterSpeedKey) != nil else {
                return Double(defaultRecenterSpeed)
            }
            return UserDefaults.standard.double(forKey: trackRecenterSpeedKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: trackRecenterSpeedKey) }
    }
    static let defaultConfidenceThreshold: Float = 0.6

    static let defaultSmoothingEnabled: Bool = true
    static let defaultSmoothingBaseAlpha: Double = 0.3
    static let defaultSmoothingMinDeviation: Double = 0.02
    static let defaultSmoothingMaxDeviation: Double = 0.05
    static let defaultSmoothingCenterFloor: Double = 0.3

    static var smoothingEnabled: Bool {
        get {
            guard UserDefaults.standard.object(forKey: smoothingEnabledKey) != nil else {
                return defaultSmoothingEnabled
            }
            return UserDefaults.standard.bool(forKey: smoothingEnabledKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: smoothingEnabledKey) }
    }
    static var smoothingBaseAlpha: Double {
        get {
            guard UserDefaults.standard.object(forKey: smoothingBaseAlphaKey) != nil else {
                return defaultSmoothingBaseAlpha
            }
            return UserDefaults.standard.double(forKey: smoothingBaseAlphaKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: smoothingBaseAlphaKey) }
    }
    static var smoothingMinDeviation: Double {
        get {
            guard UserDefaults.standard.object(forKey: smoothingMinDeviationKey) != nil else {
                return defaultSmoothingMinDeviation
            }
            return UserDefaults.standard.double(forKey: smoothingMinDeviationKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: smoothingMinDeviationKey) }
    }
    static var smoothingMaxDeviation: Double {
        get {
            guard UserDefaults.standard.object(forKey: smoothingMaxDeviationKey) != nil else {
                return defaultSmoothingMaxDeviation
            }
            return UserDefaults.standard.double(forKey: smoothingMaxDeviationKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: smoothingMaxDeviationKey) }
    }
    static var smoothingCenterFloor: Double {
        get {
            guard UserDefaults.standard.object(forKey: smoothingCenterFloorKey) != nil else {
                return defaultSmoothingCenterFloor
            }
            return UserDefaults.standard.double(forKey: smoothingCenterFloorKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: smoothingCenterFloorKey) }
    }

    // Stabilizer defaults
    static let defaultFov: Float = 100.0
    static var fov: Float {
        get {
            guard UserDefaults.standard.object(forKey: fovKey) != nil else {
                return defaultFov
            }
            return Float(UserDefaults.standard.double(forKey: fovKey))
        }
        set { UserDefaults.standard.set(Double(newValue), forKey: fovKey) }
    }
    static let defaultDistRatio: Float = 0.0
    static var distRatio: Float {
        get {
            guard UserDefaults.standard.object(forKey: distRatioKey) != nil else {
                return defaultDistRatio
            }
            return Float(UserDefaults.standard.double(forKey: distRatioKey))
        }
        set { UserDefaults.standard.set(Double(newValue), forKey: distRatioKey) }
    }
    static let defaultYaw: Float   = 0.0
    static var yaw: Float {
        get {
            guard UserDefaults.standard.object(forKey: yawKey) != nil else {
                return defaultYaw
            }
            return Float(UserDefaults.standard.double(forKey: yawKey))
        }
        set { UserDefaults.standard.set(Double(newValue), forKey: yawKey) }
    }
    static let defaultPitch: Float = 0.0
    static var pitch: Float {
        get {
            guard UserDefaults.standard.object(forKey: pitchKey) != nil else {
                return defaultPitch
            }
            return Float(UserDefaults.standard.double(forKey: pitchKey))
        }
        set { UserDefaults.standard.set(Double(newValue), forKey: pitchKey) }
    }
    static let defaultRoll: Float  = 0.0
    static var roll: Float {
        get {
            guard UserDefaults.standard.object(forKey: rollKey) != nil else {
                return defaultRoll
            }
            return Float(UserDefaults.standard.double(forKey: rollKey))
        }
        set { UserDefaults.standard.set(Double(newValue), forKey: rollKey) }
    }
    static let defaultStabEnabled: Bool = true
    static var stabEnabled: Bool {
        get {
            guard UserDefaults.standard.object(forKey: stabEnabledKey) != nil else {
                return defaultStabEnabled
            }
            return UserDefaults.standard.bool(forKey: stabEnabledKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: stabEnabledKey) }
    }
    static let defaultPreviewEnabled: Bool = true
    static var previewEnabled: Bool {
        get {
            guard UserDefaults.standard.object(forKey: previewEnabledKey) != nil else {
                return defaultPreviewEnabled
            }
            return UserDefaults.standard.bool(forKey: previewEnabledKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: previewEnabledKey) }
    }
    static let defaultYoloEnabled: Bool = true
    static var yoloEnabled: Bool {
        get {
            guard UserDefaults.standard.object(forKey: yoloEnabledKey) != nil else {
                return defaultYoloEnabled
            }
            return UserDefaults.standard.bool(forKey: yoloEnabledKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: yoloEnabledKey) }
    }

    // IMU sync (runtime-adjustable, persisted)
    static var syncOffsetMs: Double {
        get {
            guard UserDefaults.standard.object(forKey: syncOffsetKey) != nil else {
                return defaultSyncOffsetMs
            }
            return UserDefaults.standard.double(forKey: syncOffsetKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: syncOffsetKey) }
    }
    static var readoutTimeMs: Double {
        get {
            guard UserDefaults.standard.object(forKey: readoutTimeKey) != nil else {
                return defaultReadoutTimeMs
            }
            return UserDefaults.standard.double(forKey: readoutTimeKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: readoutTimeKey) }
    }
    static let defaultSyncOffsetMs: Double = -25.0
    static let defaultReadoutTimeMs: Double = 9.18
    
    // UserDefaults keys
    private static let syncOffsetKey = "com.maimai.syncOffsetMs"
    private static let readoutTimeKey = "com.maimai.readoutTimeMs"
    private static let yoloPaddingKey = "com.maimai.yoloPadding"
    private static let yoloPreviewEnabledKey = "com.maimai.yoloPreviewEnabled"
    private static let yoloOverlayEnabledKey = "com.maimai.yoloOverlayEnabled"
    private static let yoloOverlayScaleKey = "com.maimai.yoloOverlayScale"
    private static let yoloTargetFPSKey = "com.maimai.yoloTargetFPS"
    private static let focusValueKey = "com.maimai.focusValue"
    private static let shutterTimescaleKey = "com.maimai.shutterTimescale"
    private static let isoValueKey = "com.maimai.isoValue"
    private static let selectedLensKey = "com.maimai.selectedLens"
    private static let fovKey = "com.maimai.fov"
    private static let distRatioKey = "com.maimai.distRatio"
    private static let yawKey = "com.maimai.yaw"
    private static let pitchKey = "com.maimai.pitch"
    private static let rollKey = "com.maimai.roll"
    private static let stabEnabledKey = "com.maimai.stabEnabled"
    private static let previewEnabledKey = "com.maimai.previewEnabled"
    private static let yoloEnabledKey = "com.maimai.yoloEnabled"
    private static let trackTargetRatioKey = "com.maimai.trackTargetRatio"
    private static let trackRecenterSpeedKey = "com.maimai.trackRecenterSpeed"
    private static let smoothingEnabledKey = "com.maimai.smoothingEnabled"
    private static let smoothingBaseAlphaKey = "com.maimai.smoothingBaseAlpha"
    private static let smoothingMinDeviationKey = "com.maimai.smoothingMinDeviation"
    private static let smoothingMaxDeviationKey = "com.maimai.smoothingMaxDeviation"
    private static let smoothingCenterFloorKey = "com.maimai.smoothingCenterFloor"

    // Video encoding
    static let videoBitrate: Int = 4_000_000
    static let videoMaxKeyFrameInterval = 120
    static let videoFPS: Int = 60

    // Audio encoding
    static let audioSampleRate: Double = 44100.0
    static let audioBitrate: Int = 128_000

    // Streaming buffer & reconnect
    static let streamVideoBufferFrames: Int = 120
    static let streamAudioBufferFrames: Int = 200
    static let maxReconnectAttempts: Int = 5
    static let maxReconnectDelaySeconds: Double = 16.0

    static var streamPresets: [StreamPreset] {
        get {
            guard let data = UserDefaults.standard.data(forKey: streamPresetsKey) else { return [] }
            return (try? JSONDecoder().decode([StreamPreset].self, from: data)) ?? []
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: streamPresetsKey)
            }
        }
    }
    private static let streamPresetsKey = "com.maimai.streamPresets"
}

struct StreamPreset: Codable, Identifiable {
    let id: UUID
    var name: String
    var url: String
    var streamKey: String

    init(id: UUID = UUID(), name: String, url: String, streamKey: String) {
        self.id = id
        self.name = name
        self.url = url
        self.streamKey = streamKey
    }
}
