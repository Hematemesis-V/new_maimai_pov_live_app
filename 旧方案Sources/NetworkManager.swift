import simd
import Foundation
import Network
import VideoToolbox
import CoreImage

class NetworkManager {

    static let shared = NetworkManager()

    private var listener: NWListener?
    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "com.maimai.network", qos: .userInteractive)
    
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpaceCreateDeviceRGB()

    private init() {
        do {
            listener = try NWListener(using: .tcp, on: 8080)
        } catch {
            print("NetworkManager: Listener init failed: \(error)")
            return
        }

        listener?.stateUpdateHandler = { state in
            switch state {
            case .ready:
                print("NetworkManager: Listening on port 8080")
            case .failed(let err):
                print("NetworkManager: Listener failed: \(err)")
            default:
                break
            }
        }

        listener?.newConnectionHandler = { [weak self] conn in
            self?.handleNewConnection(conn)
        }

        listener?.start(queue: queue)
    }

    private func handleNewConnection(_ conn: NWConnection) {
        print("NetworkManager: Client connected: \(conn.endpoint)")
        connection = conn

        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                print("NetworkManager: Connection ready")
            case .failed(let err):
                print("NetworkManager: Connection failed: \(err)")
                self?.cleanupConnection()
            case .cancelled:
                print("NetworkManager: Connection cancelled")
                self?.cleanupConnection()
            default:
                break
            }
        }

        conn.start(queue: queue)
    }

    private func cleanupConnection() {
        connection = nil
        print("NetworkManager: Connection cleaned up")
    }

    func sendFrame(
        buffer: CVPixelBuffer,
        frameTimestamp: Double,
        topQuat: simd_quatf,
        centerQuat: simd_quatf,
        bottomQuat: simd_quatf
    ) {
        guard let conn = connection else { return }

        let ciImage = CIImage(cvPixelBuffer: buffer)
        guard let jpegData = ciContext.jpegRepresentation(of: ciImage, colorSpace: colorSpace, options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.95]) else {
            return
        }

        let payloadSize = UInt32(jpegData.count)

        var header = Data(capacity: 64)
        if let syncData = "SYNC".data(using: .ascii) { header.append(syncData) }
        withUnsafeBytes(of: frameTimestamp) { header.append(contentsOf: $0) }
        withUnsafeBytes(of: topQuat.vector.w) { header.append(contentsOf: $0) }
        withUnsafeBytes(of: topQuat.vector.x) { header.append(contentsOf: $0) }
        withUnsafeBytes(of: topQuat.vector.y) { header.append(contentsOf: $0) }
        withUnsafeBytes(of: topQuat.vector.z) { header.append(contentsOf: $0) }
        withUnsafeBytes(of: centerQuat.vector.w) { header.append(contentsOf: $0) }
        withUnsafeBytes(of: centerQuat.vector.x) { header.append(contentsOf: $0) }
        withUnsafeBytes(of: centerQuat.vector.y) { header.append(contentsOf: $0) }
        withUnsafeBytes(of: centerQuat.vector.z) { header.append(contentsOf: $0) }
        withUnsafeBytes(of: bottomQuat.vector.w) { header.append(contentsOf: $0) }
        withUnsafeBytes(of: bottomQuat.vector.x) { header.append(contentsOf: $0) }
        withUnsafeBytes(of: bottomQuat.vector.y) { header.append(contentsOf: $0) }
        withUnsafeBytes(of: bottomQuat.vector.z) { header.append(contentsOf: $0) }
        withUnsafeBytes(of: payloadSize) { header.append(contentsOf: $0) }

        conn.send(content: header, isComplete: false, completion: .contentProcessed { _ in })
        conn.send(content: jpegData, isComplete: false, completion: .contentProcessed { error in
            if let error {
                print("NetworkManager: Send failed: \(error)")
            }
        })
    }

    func sendAudio(pcmData: Data, timestamp: Double) {
        guard let conn = connection else { return }

        let payloadSize = UInt32(pcmData.count)

        var header = Data(capacity: 16)
        if let audaData = "AUDA".data(using: .ascii) { header.append(audaData) }
        withUnsafeBytes(of: timestamp) { header.append(contentsOf: $0) }
        withUnsafeBytes(of: payloadSize) { header.append(contentsOf: $0) }

        conn.send(content: header, isComplete: false, completion: .contentProcessed { _ in })
        conn.send(content: pcmData, isComplete: false, completion: .contentProcessed { error in
            if let error {
                print("NetworkManager: Audio send failed: \(error)")
            }
        })
    }
}
