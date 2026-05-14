import SwiftUI
import AVFoundation
import Metal
import UIKit

struct Phase2View: View {
    @StateObject private var pipeline = LivePipelineManager()
    @State private var controlsExpanded: Bool = true
    @AppStorage("rtmpUrl") private var rtmpUrl: String = ""
    @AppStorage("streamKey") private var streamKey: String = ""

    var body: some View {
        VStack(spacing: 0) {
            previewSection
                .frame(maxHeight: .infinity)

            controlCard
        }
        .preferredColorScheme(.dark)
        .background(Color.black)
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            pipeline.start()
        }
        .onChange(of: pipeline.selectedLens) { pipeline.handleLensChange($0) }
        .onChange(of: pipeline.focusValue) { pipeline.camera.setFocus(Float($0)) }
        .onChange(of: pipeline.shutterTimescale) { _ in pipeline.applyExposure() }
        .onChange(of: pipeline.isoValue) { _ in pipeline.applyExposure() }
        .onChange(of: pipeline.syncOffsetMs) { Config.syncOffsetMs = $0 }
        .onChange(of: pipeline.readoutTimeMs) { Config.readoutTimeMs = $0 }
        .onChange(of: pipeline.audioDelayMs) {
            pipeline.camera.audioDelayMs = $0
            pipeline.streamManager.audioDelayMs = $0
        }
        .onChange(of: pipeline.stabEnabled) { _ in pipeline.updateStabilizerEnabled() }
        .onChange(of: pipeline.fov) { _ in pipeline.updateFov() }
        .onChange(of: pipeline.distRatio) { _ in pipeline.updateDistRatio() }
        .onChange(of: pipeline.yaw) { _ in pipeline.updateYaw() }
        .onChange(of: pipeline.pitch) { _ in pipeline.updatePitch() }
        .onChange(of: pipeline.roll) { _ in pipeline.updateRoll() }
        .onChange(of: pipeline.yoloPadding) { _ in pipeline.updateYoloPadding() }
        .onChange(of: pipeline.trackAlpha) { _ in pipeline.updateTrackAlpha() }
        .onChange(of: pipeline.trackMaxSpeed) { _ in pipeline.updateTrackMaxSpeed() }
        .onChange(of: pipeline.trackDeadZone) { _ in pipeline.updateTrackDeadZone() }
        .onChange(of: pipeline.trackTargetRatio) { _ in pipeline.updateTrackTargetRatio() }
        .onDisappear {
            pipeline.stop()
        }
    }

    // MARK: - Preview

    private var previewSection: some View {
        ZStack(alignment: .topTrailing) {
            if pipeline.stabEnabled, pipeline.camera.cameraAuthorized {
                if let texture = pipeline.previewTexture {
                    MetalView(device: pipeline.device, texture: texture)
                        .aspectRatio(pipeline.isCropActive ? 9.0 / 16.0 : 3.0 / 4.0, contentMode: .fit)
                }
            } else if pipeline.camera.cameraAuthorized {
                CameraPreviewView(session: pipeline.camera.session)
                    .aspectRatio(3.0 / 4.0, contentMode: .fit)
            } else {
                Rectangle()
                    .fill(Color.black)
                    .aspectRatio(3.0 / 4.0, contentMode: .fit)
                    .overlay(Text("Camera not authorized").foregroundColor(.gray))
            }

            VStack(alignment: .trailing, spacing: 2) {
                Text("FPS: \(Int(pipeline.currentFPS))")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(pipeline.currentFPS >= 55 ? .green : .orange)
                Text("Lag: \(String(format: "%.1f", pipeline.lagMs))ms")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.gray)
            }
            .padding(6)
            .background(Color.black.opacity(0.5))
            .cornerRadius(4)
            .padding(4)

            DebugOverlayView(debug: pipeline.debug)
                .padding(.leading, 4)
                .padding(.top, 4)

            if pipeline.yoloEnabled, let img = pipeline.debug.yoloPreviewImage {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Image(uiImage: img)
                            .resizable()
                            .aspectRatio(1.0, contentMode: .fit)
                            .frame(width: 100, height: 100)
                            .border(Color.cyan, width: 1)
                            .padding(4)
                    }
                }
            }
        }
    }

    // MARK: - Control Card

    private var controlCard: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    controlsExpanded.toggle()
                }
            } label: {
                HStack {
                    Text("Controls")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.white)
                    Spacer()
                    Image(systemName: controlsExpanded ? "chevron.down" : "chevron.up")
                        .font(.caption2)
                        .foregroundColor(.gray)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.gray.opacity(0.2))
            }

            if controlsExpanded {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 8) {
                        lensPicker
                        shutterRow
                        isoRow
                        focusRow
                        stabilizerToggleRow
                        fovRow
                        distRatioRow
                        yawPitchRollRow
                        syncRow
                        audioDelayRow
                        yoloToggleRow
                        yoloPaddingRow
                        trackingSectionHeader
                        trackAlphaRow
                        trackMaxSpeedRow
                        trackDeadZoneRow
                        trackTargetRatioRow
                        liveStreamSectionHeader
                        rtmpUrlRow
                        streamKeyRow
                        resolutionRow
                        bitrateRow
                        streamButtonRow
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                .frame(maxHeight: 240)
            }
        }
        .background(.ultraThinMaterial)
        .cornerRadius(10, corners: [.topLeft, .topRight])
    }

    // MARK: - Control Rows

    private var lensPicker: some View {
        Picker("Lens", selection: $pipeline.selectedLens) {
            ForEach(LensType.allCases, id: \.self) { lens in
                Text(lens.rawValue).tag(lens)
            }
        }
        .pickerStyle(.segmented)
    }

    private var shutterRow: some View {
        HStack {
            Text("Shutter").font(.caption).frame(width: 55, alignment: .leading)
            Spacer()
            Button("1/244") {
                pipeline.shutterTimescale = 244.0; pipeline.applyExposure()
            }
            .buttonStyle(.borderedProminent)
            .tint(pipeline.shutterTimescale == 244.0 ? .orange : .gray)
            .controlSize(.small)
            .disabled(pipeline.camera.exposureMode != .custom)

            Button("1/122") {
                pipeline.shutterTimescale = 122.0; pipeline.applyExposure()
            }
            .buttonStyle(.borderedProminent)
            .tint(pipeline.shutterTimescale == 122.0 ? .orange : .gray)
            .controlSize(.small)
            .disabled(pipeline.camera.exposureMode != .custom)

            Spacer()
            Button(pipeline.camera.exposureMode == .custom ? "M" : "A") {
                pipeline.camera.exposureMode == .custom
                    ? pipeline.camera.setAutoExposure()
                    : pipeline.camera.setCustomExposure()
            }
            .buttonStyle(.borderedProminent)
            .tint(pipeline.camera.exposureMode == .custom ? .orange : .green)
            .controlSize(.small)
            .font(.caption2)
        }
    }

    private var isoRow: some View {
        labeledRow("ISO") {
            Slider(value: $pipeline.isoValue, in: pipeline.minISO...pipeline.maxISO, step: 1)
        } valueLabel: {
            Text("\(Int(pipeline.isoValue))").font(.caption).foregroundColor(.gray).frame(width: 40, alignment: .trailing)
        }
        .disabled(pipeline.camera.exposureMode != .custom)
        .onChange(of: pipeline.camera.isRunning) { running in
            if running { pipeline.updateISORange() }
        }
    }

    private var focusRow: some View {
        labeledRow("Focus") {
            Slider(value: $pipeline.focusValue, in: 0...1)
        } valueLabel: {
            Text(String(format: "%.2f", pipeline.focusValue)).font(.caption).foregroundColor(.gray).frame(width: 40, alignment: .trailing)
        }
    }

    private var stabilizerToggleRow: some View {
        HStack {
            Text("Stabilizer").font(.caption).frame(width: 55, alignment: .leading)
            Toggle("", isOn: $pipeline.stabEnabled).labelsHidden()
            Spacer()
            Text("Lag: \(String(format: "%.1f", pipeline.lagMs))ms")
                .font(.caption2).foregroundColor(.gray)
        }
    }

    private var fovRow: some View {
        labeledRow("FOV") {
            Slider(value: Binding(get: { Double(pipeline.fov) }, set: { pipeline.fov = Float($0) }), in: 30...160, step: 1)
        } valueLabel: {
            Text("\(Int(pipeline.fov))°").font(.caption).foregroundColor(.gray).frame(width: 40, alignment: .trailing)
        }
    }

    private var distRatioRow: some View {
        labeledRow("Dist") {
            Slider(value: Binding(get: { Double(pipeline.distRatio) }, set: { pipeline.distRatio = Float($0) }), in: 0...1)
        } valueLabel: {
            Text(String(format: "%.2f", pipeline.distRatio)).font(.caption).foregroundColor(.gray).frame(width: 40, alignment: .trailing)
        }
    }

    private var yawPitchRollRow: some View {
        VStack(spacing: 4) {
            labeledRow("Yaw") {
                Slider(value: Binding(get: { Double(pipeline.yaw) }, set: { pipeline.yaw = Float($0) }), in: -30...30)
            } valueLabel: {
                Text(String(format: "%.1f", pipeline.yaw)).font(.caption).foregroundColor(.gray).frame(width: 40, alignment: .trailing)
            }
            labeledRow("Pitch") {
                Slider(value: Binding(get: { Double(pipeline.pitch) }, set: { pipeline.pitch = Float($0) }), in: -30...30)
            } valueLabel: {
                Text(String(format: "%.1f", pipeline.pitch)).font(.caption).foregroundColor(.gray).frame(width: 40, alignment: .trailing)
            }
            labeledRow("Roll") {
                Slider(value: Binding(get: { Double(pipeline.roll) }, set: { pipeline.roll = Float($0) }), in: -15...15)
            } valueLabel: {
                Text(String(format: "%.1f", pipeline.roll)).font(.caption).foregroundColor(.gray).frame(width: 40, alignment: .trailing)
            }
        }
    }

    private var syncRow: some View {
        Group {
            labeledRow("Sync") {
                Slider(value: $pipeline.syncOffsetMs, in: -50...50)
            } valueLabel: {
                Text(String(format: "%.0f", pipeline.syncOffsetMs)).font(.caption).foregroundColor(.gray).frame(width: 40, alignment: .trailing)
            }
            labeledRow("Readout") {
                Slider(value: $pipeline.readoutTimeMs, in: 5...15)
            } valueLabel: {
                Text(String(format: "%.1f", pipeline.readoutTimeMs)).font(.caption).foregroundColor(.gray).frame(width: 40, alignment: .trailing)
            }
        }
    }

    private var audioDelayRow: some View {
        labeledRow("AudioDel") {
            Slider(value: $pipeline.audioDelayMs, in: -200...200)
        } valueLabel: {
            Text("\(Int(pipeline.audioDelayMs))ms").font(.caption).foregroundColor(.gray).frame(width: 40, alignment: .trailing)
        }
    }

    private var yoloToggleRow: some View {
        HStack {
            Text("YOLO").font(.caption).frame(width: 55, alignment: .leading)
            Toggle("", isOn: $pipeline.yoloEnabled).labelsHidden()
            Spacer()
            Text(pipeline.yoloEnabled ? "ON" : "OFF")
                .font(.caption2)
                .foregroundColor(pipeline.yoloEnabled ? .green : .red)
        }
    }

    private var yoloPaddingRow: some View {
        labeledRow("YOLOPad") {
            Slider(value: $pipeline.yoloPadding, in: 0...100, step: 1)
        } valueLabel: {
            Text("\(Int(pipeline.yoloPadding))px").font(.caption).foregroundColor(.gray).frame(width: 40, alignment: .trailing)
        }
    }

    private var trackAlphaRow: some View {
        labeledRow("Alpha") {
            Slider(value: $pipeline.trackAlpha, in: 0.01...1.0, step: 0.01)
        } valueLabel: {
            Text(String(format: "%.2f", pipeline.trackAlpha)).font(.caption).foregroundColor(.gray).frame(width: 40, alignment: .trailing)
        }
    }

    private var trackMaxSpeedRow: some View {
        labeledRow("MaxSpeed") {
            Slider(value: $pipeline.trackMaxSpeed, in: 1...30, step: 1)
        } valueLabel: {
            Text("\(Int(pipeline.trackMaxSpeed))").font(.caption).foregroundColor(.gray).frame(width: 40, alignment: .trailing)
        }
    }

    private var trackDeadZoneRow: some View {
        labeledRow("DeadZone") {
            Slider(value: $pipeline.trackDeadZone, in: 0...50, step: 1)
        } valueLabel: {
            Text("\(Int(pipeline.trackDeadZone))").font(.caption).foregroundColor(.gray).frame(width: 40, alignment: .trailing)
        }
    }

    private var trackTargetRatioRow: some View {
        labeledRow("TargetRatio") {
            Slider(value: $pipeline.trackTargetRatio, in: 0.1...1.0, step: 0.05)
        } valueLabel: {
            Text(String(format: "%.2f", pipeline.trackTargetRatio)).font(.caption).foregroundColor(.gray).frame(width: 40, alignment: .trailing)
        }
    }

    private var trackingSectionHeader: some View {
        HStack {
            Text("Tracking")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white)
            Spacer()
        }
        .padding(.top, 8)
    }

    private var liveStreamSectionHeader: some View {
        HStack {
            Text("Live Stream")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white)
            Spacer()
            if pipeline.streamManager.isStreaming {
                Circle()
                    .fill(Color.red)
                    .frame(width: 8, height: 8)
            }
        }
        .padding(.top, 8)
    }

    private var rtmpUrlRow: some View {
        HStack {
            Text("URL").font(.caption).frame(width: 55, alignment: .leading)
            TextField("rtmp://...", text: $rtmpUrl)
                .font(.system(size: 11, design: .monospaced))
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .disabled(pipeline.streamManager.isStreaming)
        }
    }

    private var streamKeyRow: some View {
        HStack {
            Text("Key").font(.caption).frame(width: 55, alignment: .leading)
            SecureField("stream-key", text: $streamKey)
                .font(.system(size: 11, design: .monospaced))
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .disabled(pipeline.streamManager.isStreaming)
        }
    }

    private var resolutionRow: some View {
        HStack {
            Text("Res").font(.caption).frame(width: 55, alignment: .leading)
            Picker("", selection: Binding(
                get: { pipeline.streamManager.streamResolution },
                set: { pipeline.streamManager.streamResolution = $0 }
            )) {
                ForEach(StreamResolution.allCases, id: \.self) { res in
                    Text(res.rawValue).tag(res)
                }
            }
            .pickerStyle(.segmented)
            .disabled(pipeline.streamManager.isStreaming)
            Spacer()
            if pipeline.streamManager.isStreaming {
                Text("断开后可切换")
                    .font(.system(size: 9))
                    .foregroundColor(.gray)
            }
        }
    }

    private var bitrateRow: some View {
        labeledRow("Bitrate") {
            Slider(value: Binding(
                get: { Double(pipeline.streamManager.videoBitrate) },
                set: { pipeline.streamManager.videoBitrate = Int($0) }
            ), in: 1000...10000, step: 500)
        } valueLabel: {
            Text("\(pipeline.streamManager.videoBitrate)kbps")
                .font(.caption)
                .foregroundColor(.gray)
                .frame(width: 60, alignment: .trailing)
        }
    }

    private var streamButtonRow: some View {
        HStack {
            if pipeline.streamManager.isStreaming {
                Button {
                    pipeline.streamManager.stopPublish()
                } label: {
                    HStack {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 8, height: 8)
                        Text("停止推流")
                            .font(.caption)
                            .fontWeight(.medium)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.small)
            } else {
                Button {
                    pipeline.streamManager.startPublish(url: rtmpUrl, streamKey: streamKey)
                } label: {
                    HStack {
                        Image(systemName: "arrow.up.circle")
                            .font(.caption)
                        Text("开始推流")
                            .font(.caption)
                            .fontWeight(.medium)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .controlSize(.small)
                .disabled(rtmpUrl.isEmpty || streamKey.isEmpty)
            }

            Text(pipeline.streamManager.streamStatus)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(statusColor(pipeline.streamManager.streamStatus))
                .lineLimit(1)
        }
    }

    private func statusColor(_ status: String) -> Color {
        switch status {
        case "Publishing": return .green
        case "Connecting", "Connected": return .yellow
        case "Idle": return .gray
        default: return .red
        }
    }

    // MARK: - Helpers

    private func labeledRow<C: View, V: View>(
        _ label: String,
        @ViewBuilder content: () -> C,
        @ViewBuilder valueLabel: () -> V
    ) -> some View {
        HStack(spacing: 4) {
            Text(label).font(.caption).frame(width: 55, alignment: .leading)
            content()
            valueLabel()
        }
    }
}

// MARK: - Camera preview (fallback)

private final class PreviewView2: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
}

private struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession
    func makeUIView(context: Context) -> PreviewView2 {
        let v = PreviewView2()
        v.previewLayer.session = session
        v.previewLayer.videoGravity = .resizeAspectFill
        v.previewLayer.connection?.videoOrientation = .portrait
        v.backgroundColor = .black
        return v
    }
    func updateUIView(_ uiView: PreviewView2, context: Context) {}
}

// MARK: - Corner radius helper

extension View {
    func cornerRadius(_ radius: CGFloat, corners: UIRectCorner) -> some View {
        clipShape(RoundedCorner(radius: radius, corners: corners))
    }
}

private struct RoundedCorner: Shape {
    var radius: CGFloat = .infinity
    var corners: UIRectCorner = .allCorners
    func path(in rect: CGRect) -> Path {
        let p = UIBezierPath(
            roundedRect: rect,
            byRoundingCorners: corners,
            cornerRadii: CGSize(width: radius, height: radius)
        )
        return Path(p.cgPath)
    }
}
