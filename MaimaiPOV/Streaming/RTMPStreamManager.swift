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
    @Published var audioDelayMs: Double = 0.0

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

        let vStream = AsyncStream<CMSampleBuffer> { continuation in
            self.videoContinuation = continuation
        }
        videoIngestTask = Task { [weak stream] in
            for await buffer in vStream {
                await stream?.append(buffer)
            }
        }

        let aStream = AsyncStream<(AVAudioBuffer, AVAudioTime)> { continuation in
            self.audioContinuation = continuation
        }
        audioIngestTask = Task { [weak stream] in
            for await (buffer, when) in aStream {
                await stream?.append(buffer, when: when)
            }
        }

        isStreaming = true
        streamStatus = "Connecting"
        DebugInfoManager.shared.rtmpStatus = "Connecting"
        DebugInfoManager.shared.log("RTMP: Connecting")

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

        Task { [weak self] in
            do {
                _ = try await connection.connect(url)
                _ = try await stream.publish(streamKey)
                await MainActor.run {
                    self?.streamStatus = "Publishing"
                    DebugInfoManager.shared.rtmpStatus = "Publishing"
                    DebugInfoManager.shared.log("RTMP: Publishing")
                }
            } catch {
                await MainActor.run {
                    self?.streamStatus = "Failed: \(error.localizedDescription)"
                    DebugInfoManager.shared.rtmpStatus = "Failed"
                    DebugInfoManager.shared.log("RTMP: Failed - \(error.localizedDescription)")
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

        videoContinuation?.yield(finalSampleBuffer)
    }

    func appendAudio(sampleBuffer: CMSampleBuffer) {
        guard isStreaming else { return }

        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
        let audioFormat = AVAudioFormat(cmAudioFormatDescription: formatDescription)

        let frameCount = AVAudioFrameCount(sampleBuffer.numSamples)
        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: frameCount) else { return }

        var audioBufferList = AudioBufferList()
        var blockBuffer: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: &audioBufferList,
            bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr else { return }

        let numChannels = Int(audioFormat.channelCount)
        let srcBuffer = audioBufferList.mBuffers
        guard let srcData = srcBuffer.mData else { return }

        for ch in 0..<numChannels {
            guard let dst = pcmBuffer.floatChannelData?[ch] else { continue }
            let src = srcData.assumingMemoryBound(to: Float.self).advanced(by: ch)
            for i in 0..<Int(frameCount) {
                dst[i] = src.advanced(by: numChannels * i).pointee
            }
        }
        pcmBuffer.frameLength = frameCount

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let sampleTime = AVAudioFramePosition(CMTimeGetSeconds(pts) * audioFormat.sampleRate)
        var audioTime = AVAudioTime(sampleTime: sampleTime, atRate: audioFormat.sampleRate)

        let delayMs = audioDelayMs
        if delayMs != 0 {
            let delaySeconds = delayMs / 1000.0
            let hostTime = AVAudioTime.hostTime(forSeconds: delaySeconds)
            if let currentHostTime = audioTime.hostTime {
                let adjustedHostTime = currentHostTime + hostTime
                let adjustedSampleTime = sampleTime + AVAudioFramePosition(delaySeconds * audioFormat.sampleRate)
                audioTime = AVAudioTime(hostTime: adjustedHostTime, sampleTime: adjustedSampleTime, atRate: audioFormat.sampleRate)
            }
        }

        audioContinuation?.yield((pcmBuffer, audioTime))
    }

    @MainActor
    private func handleConnectionStatus(_ code: String) {
        switch code {
        case "NetConnection.Connect.Success":
            streamStatus = "Connected"
            DebugInfoManager.shared.rtmpStatus = "Connected"
            DebugInfoManager.shared.log("RTMP: Connected")
        case "NetConnection.Connect.Closed", "NetConnection.Connect.Failed", "NetConnection.Connect.Rejected":
            streamStatus = code.components(separatedBy: ".").last ?? "Error"
            DebugInfoManager.shared.rtmpStatus = streamStatus
            DebugInfoManager.shared.log("RTMP: \(streamStatus)")
            isStreaming = false
            cleanup()
        default: break
        }
    }

    @MainActor
    private func handleStreamStatus(_ code: String) {
        switch code {
        case "NetStream.Publish.Start":
            streamStatus = "Publishing"
            DebugInfoManager.shared.rtmpStatus = "Publishing"
            DebugInfoManager.shared.log("RTMP: Publishing")
        case "NetStream.Publish.BadName":
            streamStatus = "BadName"
            DebugInfoManager.shared.rtmpStatus = "BadName"
            DebugInfoManager.shared.log("RTMP: BadName")
        case "NetStream.Connect.Closed", "NetStream.Unpublish.Success":
            if isStreaming {
                streamStatus = "Stream Closed"
                DebugInfoManager.shared.rtmpStatus = "Stream Closed"
                DebugInfoManager.shared.log("RTMP: Stream closed")
                isStreaming = false
                cleanup()
            }
        default: break
        }
    }

    private func cleanup() {
        statusTask?.cancel()
        statusTask = nil
        streamStatusTask?.cancel()
        streamStatusTask = nil
        statsTask?.cancel()
        statsTask = nil

        videoContinuation?.finish()
        videoContinuation = nil
        audioContinuation?.finish()
        audioContinuation = nil
        videoIngestTask?.cancel()
        videoIngestTask = nil
        audioIngestTask?.cancel()
        audioIngestTask = nil

        lock.lock()
        stream = nil
        connection = nil
        lock.unlock()
        videoFormatDescription = nil
    }
}
