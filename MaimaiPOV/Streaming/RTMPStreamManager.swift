import SwiftUI
import HaishinKit
import CoreMedia
import VideoToolbox
import AVFAudio

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

    private struct AudioSyncEntry {
        let pcmBuffer: AVAudioPCMBuffer
        let audioTime: AVAudioTime
        let alignedTime: Double
    }

    private var audioSyncQueue: [AudioSyncEntry] = []
    private let audioSyncLock = NSLock()
    private let audioQueueMaxDuration: Double = 0.2

    var audioSyncQueueDepth: Int {
        audioSyncLock.lock()
        defer { audioSyncLock.unlock() }
        return audioSyncQueue.count
    }

    private var connection: RTMPConnection?
    private var stream: RTMPStream?

    private var statusTask: Task<Void, Never>?
    private var streamStatusTask: Task<Void, Never>?
    private var statsTask: Task<Void, Never>?

    private var videoIngestTask: Task<Void, Never>?
    private var audioIngestTask: Task<Void, Never>?
    private var videoContinuation: AsyncStream<CMSampleBuffer>.Continuation?
    private var audioContinuation: AsyncStream<(AVAudioBuffer, AVAudioTime)>.Continuation?

    private var videoFormatDescription: CMVideoFormatDescription?
    private let lock = NSLock()

    private var rtmpUrl: String = ""
    private var streamKey: String = ""
    private var reconnectAttempt: Int = 0
    private var reconnectTask: Task<Void, Never>?

    private var videoBufferCount: Int = 0
    private var audioBufferCount: Int = 0
    private let bufferCountLock = NSLock()

    @MainActor
    func startPublish(url: String, streamKey: String) {
        guard !isStreaming else { return }
        guard !url.isEmpty, !streamKey.isEmpty else {
            streamStatus = "Error: URL/Key empty"
            return
        }
        self.rtmpUrl = url
        self.streamKey = streamKey
        self.reconnectAttempt = 0
        isStreaming = true
        connectAndPublish()
    }

    private func connectAndPublish() {
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

        setupStreamPipelines(stream)

        let attempt = reconnectAttempt
        Task { @MainActor in
            if attempt > 0 {
                self.streamStatus = "重连中(\(attempt)/\(Config.maxReconnectAttempts))..."
            } else {
                self.streamStatus = "Connecting"
            }
            DebugInfoManager.shared.rtmpStatus = self.streamStatus
            DebugInfoManager.shared.log("RTMP: \(self.streamStatus)")
        }

        setupStatusMonitoring(connection: connection, stream: stream)

        Task { [weak self] in
            do {
                _ = try await connection.connect(rtmpUrl)
                _ = try await stream.publish(streamKey)
                await MainActor.run {
                    self?.reconnectAttempt = 0
                    self?.streamStatus = "Publishing"
                    DebugInfoManager.shared.rtmpStatus = "Publishing"
                    DebugInfoManager.shared.log("RTMP: Publishing")
                }
            } catch {
                await MainActor.run {
                    self?.attemptReconnect(reason: error.localizedDescription)
                }
            }
        }
    }

    private func setupStreamPipelines(_ stream: RTMPStream) {
        let (vStream, vContinuation) = AsyncStream<CMSampleBuffer>.makeStream(
            of: CMSampleBuffer.self,
            bufferingPolicy: .bufferingNewest(Config.streamVideoBufferFrames)
        )
        videoContinuation = vContinuation
        videoIngestTask = Task { [weak self, weak stream] in
            for await buffer in vStream {
                self?.decrementVideoBufferCount()
                await stream?.append(buffer)
            }
        }

        let (aStream, aContinuation) = AsyncStream<(AVAudioBuffer, AVAudioTime)>.makeStream(
            of: (AVAudioBuffer, AVAudioTime).self,
            bufferingPolicy: .bufferingNewest(Config.streamAudioBufferFrames)
        )
        audioContinuation = aContinuation
        audioIngestTask = Task { [weak self, weak stream] in
            for await (buffer, when) in aStream {
                self?.decrementAudioBufferCount()
                await stream?.append(buffer, when: when)
            }
        }
    }

    private func setupStatusMonitoring(connection: RTMPConnection, stream: RTMPStream) {
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

        statsTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { break }
                let currentStream: RTMPStream?
                self.lock.lock()
                currentStream = self.stream
                self.lock.unlock()
                guard let currentStream else { break }
                let info = await currentStream.info
                let fps = await currentStream.currentFPS
                DispatchQueue.main.async {
                    DebugInfoManager.shared.rtmpBitrate = info.currentBytesPerSecond * 8 / 1000
                    DebugInfoManager.shared.rtmpFPS = Int(fps)
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    @MainActor
    func stopPublish() {
        guard isStreaming else { return }
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnectAttempt = 0

        let stream: RTMPStream?
        let connection: RTMPConnection?
        lock.lock()
        stream = self.stream
        connection = self.connection
        lock.unlock()

        Task {
            if let stream { _ = try? await stream.close() }
            if let connection { try? await connection.close() }
        }

        isStreaming = false
        streamStatus = "Idle"
        DebugInfoManager.shared.rtmpStatus = "Idle"
        DebugInfoManager.shared.rtmpBitrate = 0
        DebugInfoManager.shared.rtmpFPS = 0
        DebugInfoManager.shared.log("RTMP: Stopped")
        cleanup()
    }

    func appendVideo(pixelBuffer: CVPixelBuffer, timestamp: CMTime) {
        guard isStreaming else { return }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)

        var needsNewFormat = false
        if let desc = videoFormatDescription {
            let descDimensions = CMVideoFormatDescriptionGetDimensions(desc)
            let descCodec = CMFormatDescriptionGetMediaSubType(desc)
            if descDimensions.width != width || descDimensions.height != height || descCodec != pixelFormat {
                needsNewFormat = true
            }
        } else {
            needsNewFormat = true
        }

        if needsNewFormat {
            var newDesc: CMVideoFormatDescription?
            let status = CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault,
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
        let result = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: formatDescription,
            sampleTiming: &timingInfo,
            sampleBufferOut: &sampleBuffer
        )

        guard result == noErr, let finalSampleBuffer = sampleBuffer else { return }

        bufferCountLock.lock()
        videoBufferCount += 1
        let count = videoBufferCount
        bufferCountLock.unlock()

        if count > Int(Double(Config.streamVideoBufferFrames) * 1.5) {
            forceClearBuffers()
            return
        }

        let videoTimeSeconds = timestamp.seconds
        audioSyncLock.lock()
        var audioToRelease: [(AVAudioPCMBuffer, AVAudioTime)] = []
        while !audioSyncQueue.isEmpty, audioSyncQueue.first!.alignedTime <= videoTimeSeconds {
            let entry = audioSyncQueue.removeFirst()
            audioToRelease.append((entry.pcmBuffer, entry.audioTime))
        }
        audioSyncLock.unlock()

        for (buffer, time) in audioToRelease {
            decrementAudioBufferCount()
            audioContinuation?.yield((buffer, time))
        }

        videoContinuation?.yield(finalSampleBuffer)
    }

    func appendAudio(sampleBuffer: CMSampleBuffer, alignedTime: Double) {
        guard isStreaming else { return }

        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
        let audioFormat = AVAudioFormat(cmAudioFormatDescription: formatDescription)

        let frameCount = AVAudioFrameCount(sampleBuffer.numSamples)
        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: frameCount) else { return }
        pcmBuffer.frameLength = frameCount

        let copyStatus = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frameCount),
            into: pcmBuffer.mutableAudioBufferList
        )
        guard copyStatus == noErr else { return }

        let sampleTime = AVAudioFramePosition(alignedTime * audioFormat.sampleRate)
        let audioTime = AVAudioTime(sampleTime: sampleTime, atRate: audioFormat.sampleRate)

        audioSyncLock.lock()
        audioSyncQueue.append(AudioSyncEntry(
            pcmBuffer: pcmBuffer, audioTime: audioTime, alignedTime: alignedTime
        ))
        while audioSyncQueue.count > 1,
              audioSyncQueue.last!.alignedTime - audioSyncQueue.first!.alignedTime > audioQueueMaxDuration {
            audioSyncQueue.removeFirst()
        }
        audioSyncLock.unlock()
    }

    @MainActor
    private func attemptReconnect(reason: String? = nil) {
        reconnectAttempt += 1
        if reconnectAttempt > Config.maxReconnectAttempts {
            streamStatus = "重连失败，请手动重试"
            DebugInfoManager.shared.rtmpStatus = "重连失败"
            DebugInfoManager.shared.log("RTMP: 重连失败 - \(reason ?? "unknown")")
            isStreaming = false
            cleanup()
            return
        }

        let delay = min(pow(2.0, Double(reconnectAttempt - 1)), Config.maxReconnectDelaySeconds)
        streamStatus = "重连中(\(reconnectAttempt)/\(Config.maxReconnectAttempts))..."
        DebugInfoManager.shared.rtmpStatus = streamStatus
        DebugInfoManager.shared.log("RTMP: \(streamStatus) \(String(format: "%.0fs后重试", delay))")

        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, self.isStreaming else { return }
            self.resetStreams()
            await MainActor.run {
                self.connectAndPublish()
            }
        }
    }

    @MainActor
    private func handleConnectionStatus(_ code: String) {
        switch code {
        case "NetConnection.Connect.Success":
            streamStatus = "Connected"
            DebugInfoManager.shared.rtmpStatus = "Connected"
            DebugInfoManager.shared.log("RTMP: Connected")
        case "NetConnection.Connect.Closed":
            attemptReconnect(reason: "连接关闭")
        case "NetConnection.Connect.Failed":
            attemptReconnect(reason: "连接失败")
        case "NetConnection.Connect.Rejected":
            streamStatus = "Rejected"
            DebugInfoManager.shared.rtmpStatus = "Rejected"
            DebugInfoManager.shared.log("RTMP: Rejected - 不重连")
            isStreaming = false
            cleanup()
        default: break
        }
    }

    @MainActor
    private func handleStreamStatus(_ code: String) {
        switch code {
        case "NetStream.Publish.Start":
            if reconnectAttempt == 0 {
                streamStatus = "Publishing"
                DebugInfoManager.shared.rtmpStatus = "Publishing"
                DebugInfoManager.shared.log("RTMP: Publishing")
            }
        case "NetStream.Publish.BadName":
            streamStatus = "BadName"
            DebugInfoManager.shared.rtmpStatus = "BadName"
            DebugInfoManager.shared.log("RTMP: BadName")
        case "NetStream.Connect.Closed", "NetStream.Unpublish.Success":
            if isStreaming {
                attemptReconnect(reason: "流关闭")
            }
        default: break
        }
    }

    private func decrementVideoBufferCount() {
        bufferCountLock.lock()
        videoBufferCount = max(0, videoBufferCount - 1)
        bufferCountLock.unlock()
    }

    private func decrementAudioBufferCount() {
        bufferCountLock.lock()
        audioBufferCount = max(0, audioBufferCount - 1)
        bufferCountLock.unlock()
    }

    private func forceClearBuffers() {
        bufferCountLock.lock()
        videoBufferCount = 0
        audioBufferCount = 0
        bufferCountLock.unlock()
        audioSyncLock.lock()
        audioSyncQueue.removeAll()
        audioSyncLock.unlock()
        videoContinuation?.finish()
        audioContinuation?.finish()
        lock.lock()
        if let s = stream {
            videoContinuation = nil
            audioContinuation = nil
            lock.unlock()
            setupStreamPipelines(s)
        } else {
            lock.unlock()
        }
        videoFormatDescription = nil
        Task { @MainActor in
            DebugInfoManager.shared.log("RTMP: 缓冲区强制清空")
        }
    }

    private func resetStreams() {
        statusTask?.cancel(); statusTask = nil
        streamStatusTask?.cancel(); streamStatusTask = nil
        statsTask?.cancel(); statsTask = nil
        videoContinuation?.finish(); videoContinuation = nil
        audioContinuation?.finish(); audioContinuation = nil
        videoIngestTask?.cancel(); videoIngestTask = nil
        audioIngestTask?.cancel(); audioIngestTask = nil
        audioSyncLock.lock()
        audioSyncQueue.removeAll()
        audioSyncLock.unlock()
        lock.lock()
        let oldStream = stream
        let oldConnection = connection
        stream = nil
        connection = nil
        lock.unlock()
        Task {
            if let s = oldStream { _ = try? await s.close() }
            if let c = oldConnection { _ = try? await c.close() }
        }
        videoFormatDescription = nil
        bufferCountLock.lock()
        videoBufferCount = 0
        audioBufferCount = 0
        bufferCountLock.unlock()
    }

    private func cleanup() {
        reconnectTask?.cancel()
        reconnectTask = nil
        resetStreams()
    }
}
