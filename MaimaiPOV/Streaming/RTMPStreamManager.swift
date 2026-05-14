import SwiftUI
import HaishinKit
import CoreMedia
import VideoToolbox

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
    private var videoFormatDescription: CMVideoFormatDescription?
    private let lock = NSLock()

    @MainActor
    func startPublish(url: String, streamKey: String) {
        guard !isStreaming else { return }
        guard !url.isEmpty, !streamKey.isEmpty else {
            streamStatus = "Error: URL/Key empty"
            return
        }

        let connection = RTMPConnection()
        let stream = RTMPStream(connection: connection)

        let resolution = streamResolution
        let bitrate = videoBitrate

        Task {
            await stream.setVideoSettings(VideoCodecSettings(
                videoSize: resolution.size,
                bitRate: bitrate * 1000,
                profileLevel: kVTProfileLevel_H264_Main_3_1 as String
            ))
            await stream.setAudioSettings(AudioCodecSettings(bitRate: Config.audioBitrate))
        }

        lock.lock()
        self.connection = connection
        self.stream = stream
        lock.unlock()

        isStreaming = true
        streamStatus = "Connecting"
        DebugInfoManager.shared.rtmpStatus = "Connecting"

        statusTask = Task { [weak self] in
            for await status in await connection.status {
                let code = status.code
                Task { @MainActor in
                    self?.handleConnectionStatus(code)
                }
            }
        }

        streamStatusTask = Task { [weak self] in
            for await status in await stream.status {
                let code = status.code
                Task { @MainActor in
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
                    DebugInfoManager.shared.rtmpStatus = "Publishing"
                }
            } catch {
                await MainActor.run {
                    self?.streamStatus = "Failed: \(error.localizedDescription)"
                    DebugInfoManager.shared.rtmpStatus = "Failed"
                    self?.isStreaming = false
                    self?.cleanup()
                }
            }
        }
    }

    @MainActor
    func stopPublish() {
        guard isStreaming else { return }

        let stream: RTMPStream?
        let connection: RTMPConnection?
        lock.lock()
        stream = self.stream
        connection = self.connection
        lock.unlock()

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
        DebugInfoManager.shared.rtmpStatus = "Idle"
        cleanup()
    }

    func appendVideo(pixelBuffer: CVPixelBuffer, timestamp: CMTime) {
        lock.lock()
        let currentStream = stream
        let streaming = isStreaming
        lock.unlock()

        guard streaming, let currentStream else { return }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)

        var needsNewFormat = false
        if let desc = videoFormatDescription {
            let descWidth = CMVideoFormatDescriptionGetDimensions(desc).width
            let descHeight = CMVideoFormatDescriptionGetDimensions(desc).height
            let descCodec = CMFormatDescriptionGetMediaSubType(desc)
            if descWidth != width || descHeight != height || descCodec != pixelFormat {
                needsNewFormat = true
            }
        } else {
            needsNewFormat = true
        }

        if needsNewFormat {
            var newDesc: CMVideoFormatDescription?
            let status = CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: nil,
                imageBuffer: pixelBuffer,
                formatDescriptionOut: &newDesc
            )
            guard status == noErr, let newDesc else { return }
            videoFormatDescription = newDesc
        }

        guard let formatDescription = videoFormatDescription else { return }

        var timingInfo = CMSampleTimingInfo(
            duration: CMTimeMake(value: 1, timescale: 60),
            presentationTimeStamp: timestamp,
            decodeTimeStamp: .invalid
        )

        var sampleBuffer: CMSampleBuffer?
        let result = CMSampleBufferCreateForImageBuffer(
            allocator: nil,
            imageBuffer: pixelBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDescription,
            sampleTiming: &timingInfo,
            sampleBufferOut: &sampleBuffer
        )

        guard result == noErr, let sampleBuffer else { return }

        Task {
            await currentStream.append(sampleBuffer)
        }
    }

    func appendAudio(sampleBuffer: CMSampleBuffer) {
        lock.lock()
        let currentStream = stream
        let streaming = isStreaming
        lock.unlock()

        guard streaming, let currentStream else { return }

        Task {
            await currentStream.append(sampleBuffer)
        }
    }

    @MainActor
    private func handleConnectionStatus(_ code: String) {
        switch code {
        case "NetConnection.Connect.Success":
            streamStatus = "Connected"
            DebugInfoManager.shared.rtmpStatus = "Connected"
        case "NetConnection.Connect.Closed":
            if isStreaming {
                streamStatus = "Disconnected"
                DebugInfoManager.shared.rtmpStatus = "Disconnected"
                isStreaming = false
                cleanup()
            }
        case "NetConnection.Connect.Failed":
            streamStatus = "Failed"
            DebugInfoManager.shared.rtmpStatus = "Failed"
            isStreaming = false
            cleanup()
        case "NetConnection.Connect.Rejected":
            streamStatus = "Rejected"
            DebugInfoManager.shared.rtmpStatus = "Rejected"
            isStreaming = false
            cleanup()
        default:
            break
        }
    }

    @MainActor
    private func handleStreamStatus(_ code: String) {
        switch code {
        case "NetStream.Publish.Start":
            streamStatus = "Publishing"
            DebugInfoManager.shared.rtmpStatus = "Publishing"
        case "NetStream.Publish.BadName":
            streamStatus = "BadName"
            DebugInfoManager.shared.rtmpStatus = "BadName"
        case "NetStream.Unpublish.Success":
            streamStatus = "Unpublished"
            DebugInfoManager.shared.rtmpStatus = "Unpublished"
        case "NetStream.Connect.Closed":
            if isStreaming {
                streamStatus = "Stream Closed"
                DebugInfoManager.shared.rtmpStatus = "Stream Closed"
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
        lock.lock()
        stream = nil
        connection = nil
        lock.unlock()
        videoFormatDescription = nil
    }
}
