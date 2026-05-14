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
    static let outputWidth  = 720
    static let outputHeight = 1280

    // Tracking defaults
    static let defaultAlpha: Float = 0.1
    static let defaultMaxSpeed: Float = 5.0
    static let defaultDeadZone: Float = 8.0
    static let defaultTargetRatio: Float = 0.5
    static let defaultRecenterDecay: Float = 0.02
    static let defaultRecenterGrace: Double = 0.5
    static let defaultConfidenceThreshold: Float = 0.8

    // Stabilizer defaults
    static let defaultFov: Float = 100.0
    static let defaultDistRatio: Float = 0.0
    static let defaultYaw: Float   = 0.0
    static let defaultPitch: Float = 0.0
    static let defaultRoll: Float  = 0.0

    // IMU sync (runtime-adjustable, persisted)
    static var syncOffsetMs: Double {
        get { UserDefaults.standard.double(forKey: syncOffsetKey) }
        set { UserDefaults.standard.set(newValue, forKey: syncOffsetKey) }
    }
    static var readoutTimeMs: Double {
        get { UserDefaults.standard.double(forKey: readoutTimeKey) }
        set { UserDefaults.standard.set(newValue, forKey: readoutTimeKey) }
    }
    static let defaultSyncOffsetMs: Double = -25.0
    static let defaultReadoutTimeMs: Double = 9.18
    private static let syncOffsetKey = "com.maimai.syncOffsetMs"
    private static let readoutTimeKey = "com.maimai.readoutTimeMs"
    private static let yoloPaddingKey = "com.maimai.yoloPadding"

    // Video encoding
    static let videoBitrate: Int = 4_000_000
    static let videoMaxKeyFrameInterval = 120
    static let videoFPS: Int = 60

    // Audio encoding
    static let audioSampleRate: Double = 44100.0
    static let audioBitrate: Int = 128_000
}
