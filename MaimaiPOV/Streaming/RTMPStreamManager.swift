import SwiftUI
import HaishinKit
import CoreMedia

enum StreamResolution: String, CaseIterable {
    case r720p = "720p"
    case r1080p = "1080p"

    var size: CGSize {
        switch self {
        case .r720p: return CGSize(width: Config.outputWidth, height: Config.outputHeight)
        case .r1080p: return CGSize(width: 1080, height: 1920)
        }
    }
}

class RTMPStreamManager: ObservableObject {
    @Published var isStreaming: Bool = false
    @Published var streamStatus: String = "Idle"
    @Published var streamResolution: StreamResolution = .r720p
    @Published var videoBitrate: Int = Config.videoBitrate / 1000

    private var connection: RTMPConnection?
    private var stream: RTMPStream?
    private var statusTask: Task<Void, Never>?
    private var streamStatusTask: Task<Void, Never>?

    let debug = DebugInfoManager.shared

    func startPublish(url: String, streamKey: String) {
        guard !isStreaming else { return }
        guard !url.isEmpty, !streamKey.isEmpty else {
            streamStatus = "Error: URL/Key empty"
            return
        }

        let connection = RTMPConnection()
        let stream = RTMPStream(connection: connection)

        Task { [weak self] in
            await stream.setVideoSettings(VideoCodecSettings(
                videoSize: self?.streamResolution.size ?? StreamResolution.r720p.size,
                bitRate: (self?.videoBitrate ?? 4000) * 1000,
                profileLevel: kVTProfileLevel_H264_Main_3_1 as String
            ))
            await stream.setAudioSettings(AudioCodecSettings(bitRate: Config.audioBitrate))
        }

        self.connection = connection
        self.stream = stream

        await MainActor.run {
            self.isStreaming = true
            self.streamStatus = "Connecting"
            self.debug.rtmpStatus = "Connecting"
        }

        statusTask = Task { [weak self] in
            for await status in await connection.status {
                let code = status.code
                await MainActor.run {
                    self?.handleConnectionStatus(code)
                }
            }
        }

        streamStatusTask = Task { [weak self] in
            for await status in await stream.status {
                let code = status.code
                await MainActor.run {
                    self?.handleStreamStatus(code)
                }
            }
        }

        Task { [weak self] in
            do {
                _ = try await connection.connect(url)
                _ = try await stream.publish(streamKey)
                await MainActor.run {
                    self?.streamStatus = "Publishing"
                    self?.debug.rtmpStatus = "Publishing"
                }
            } catch {
                await MainActor.run {
                    self?.streamStatus = "Failed: \(error.localizedDescription)"
                    self?.debug.rtmpStatus = "Failed"
                    self?.isStreaming = false
                    self?.cleanup()
                }
            }
        }
    }

    func stopPublish() {
        guard isStreaming else { return }

        let stream = self.stream
        let connection = self.connection

        Task {
            if let stream {
                _ = try? await stream.close()
            }
            if let connection {
                try? await connection.close()
            }
        }

        isStreaming = false
        streamStatus = "Idle"
        debug.rtmpStatus = "Idle"
        cleanup()
    }

    func appendVideo(pixelBuffer: CVPixelBuffer, timestamp: CMTime) {
    }

    func appendAudio(sampleBuffer: CMSampleBuffer) {
    }

    private func handleConnectionStatus(_ code: String) {
        switch code {
        case "NetConnection.Connect.Success":
            streamStatus = "Connected"
            debug.rtmpStatus = "Connected"
        case "NetConnection.Connect.Closed":
            if isStreaming {
                streamStatus = "Disconnected"
                debug.rtmpStatus = "Disconnected"
                isStreaming = false
                cleanup()
            }
        case "NetConnection.Connect.Failed":
            streamStatus = "Failed"
            debug.rtmpStatus = "Failed"
            isStreaming = false
            cleanup()
        case "NetConnection.Connect.Rejected":
            streamStatus = "Rejected"
            debug.rtmpStatus = "Rejected"
            isStreaming = false
            cleanup()
        default:
            break
        }
    }

    private func handleStreamStatus(_ code: String) {
        switch code {
        case "NetStream.Publish.Start":
            streamStatus = "Publishing"
            debug.rtmpStatus = "Publishing"
        case "NetStream.Publish.BadName":
            streamStatus = "BadName"
            debug.rtmpStatus = "BadName"
        case "NetStream.Unpublish.Success":
            streamStatus = "Unpublished"
            debug.rtmpStatus = "Unpublished"
        case "NetStream.Connect.Closed":
            if isStreaming {
                streamStatus = "Stream Closed"
                debug.rtmpStatus = "Stream Closed"
                isStreaming = false
                cleanup()
            }
        default:
            break
        }
    }

    private func cleanup() {
        statusTask?.cancel()
        statusTask = nil
        streamStatusTask?.cancel()
        streamStatusTask = nil
        stream = nil
        connection = nil
    }
}
