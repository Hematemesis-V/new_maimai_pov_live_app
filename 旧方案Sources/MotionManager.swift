import CoreMotion
import Foundation
import simd

struct MotionSample {
    var timestamp: Double
    var quaternion: simd_quatf
}

enum AppSyncConfig {
    private static let syncOffsetKey = "com.maimai.syncOffsetMs"

    static var syncOffsetMs: Double {
        get { UserDefaults.standard.double(forKey: syncOffsetKey) }
        set { UserDefaults.standard.set(newValue, forKey: syncOffsetKey) }
    }
}

class MotionManager {

    static let shared = MotionManager()

    private let motionManager = CMMotionManager()
    private let lock = NSLock()
    private var headIndex = 0
    private let bufferSize = 512

    private var buffer = [MotionSample](
        repeating: MotionSample(
            timestamp: 0,
            quaternion: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        ),
        count: 512
    )

    private init() {}

    func startUpdates() {
        guard motionManager.isDeviceMotionAvailable else {
            print("MotionManager: DeviceMotion not available")
            return
        }
        motionManager.deviceMotionUpdateInterval = 1.0 / 200.0
        motionManager.startDeviceMotionUpdates(using: .xMagneticNorthZVertical, to: OperationQueue()) { [weak self] motion, error in
            guard let self, let motion else { return }
            if let error {
                print("MotionManager: Error: \(error.localizedDescription)")
                return
            }

            let timestamp = motion.timestamp
            let q = motion.attitude.quaternion
            let sample = MotionSample(
                timestamp: timestamp,
                quaternion: simd_quatf(
                    ix: Float(q.x),
                    iy: Float(q.y),
                    iz: Float(q.z),
                    r: Float(q.w)
                )
            )

            self.lock.lock()
            self.buffer[self.headIndex] = sample
            self.headIndex = (self.headIndex + 1) % self.bufferSize
            self.lock.unlock()
        }
        print("MotionManager: Started at 200Hz")
    }

    func stopUpdates() {
        motionManager.stopDeviceMotionUpdates()
        print("MotionManager: Stopped")
    }

    func getQuaternion(at targetTime: Double) -> simd_quatf? {
        lock.lock()
        defer { lock.unlock() }

        var sample1: MotionSample?
        var sample2: MotionSample?

        for i in 0..<bufferSize {
            let idx = ((headIndex - 1 - i) + bufferSize) % bufferSize
            let s = buffer[idx]
            if s.timestamp == 0 { continue }

            if s.timestamp <= targetTime {
                sample1 = s
                let nextIdx = (idx + 1) % bufferSize
                sample2 = buffer[nextIdx]
                break
            }
        }

        guard let s1 = sample1, let s2 = sample2, s2.timestamp > s1.timestamp else {
            return nil
        }

        let dt = s2.timestamp - s1.timestamp
        guard dt > 0, dt < 0.1 else { return nil }

        let ratio = Float((targetTime - s1.timestamp) / dt)
        let clampedRatio = max(0.0, min(1.0, ratio))

        return simd_slerp(s1.quaternion, s2.quaternion, clampedRatio)
    }
}
