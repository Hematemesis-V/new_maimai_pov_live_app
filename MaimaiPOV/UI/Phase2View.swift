import SwiftUI
import AVFoundation
import Metal
import UIKit

private enum ControlTab: String, CaseIterable {
    case camera = "拍摄"
    case effects = "效果"
    case stream = "推流"

    var icon: String {
        switch self {
        case .camera: return "camera"
        case .effects: return "wand.and.stars"
        case .stream: return "arrow.up.circle"
        }
    }
}

struct Phase2View: View {
    @StateObject private var pipeline = LivePipelineManager()
    @State private var selectedTab: ControlTab = .camera
    @State private var panelExpanded: Bool = true
    @State private var advancedExpanded: Bool = false
    @State private var presets: [StreamPreset] = Config.streamPresets
    @State private var showAddPresetSheet = false
    @State private var newPresetName = ""
    @State private var newPresetUrl = ""
    @State private var newPresetKey = ""
    @State private var gestureStartYaw: Float = 0
    @State private var gestureStartPitch: Float = 0
    @State private var gestureStartRoll: Float = 0
    @State private var dragStarted = false
    @State private var rotationStarted = false
    @AppStorage("rtmpUrl") private var rtmpUrl: String = ""
    @AppStorage("streamKey") private var streamKey: String = ""

    var body: some View {
        VStack(spacing: 0) {
            previewSection
                .frame(maxHeight: .infinity)

            controlPanel
        }
        .preferredColorScheme(.dark)
        .background(Color.black)
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            pipeline.start()
        }
        .onChange(of: pipeline.selectedLens) { pipeline.handleLensChange($0) }
        .onChange(of: pipeline.focusValue) { _ in pipeline.applyExposure() }
        .onChange(of: pipeline.shutterTimescale) { _ in pipeline.applyExposure() }
        .onChange(of: pipeline.isoValue) { _ in pipeline.applyExposure() }
        .onChange(of: pipeline.syncOffsetMs) { Config.syncOffsetMs = $0 }
        .onChange(of: pipeline.readoutTimeMs) {
            Config.readoutTimeMs = $0
            pipeline.updateReadoutTime()
        }
        .onChange(of: pipeline.stabEnabled) { _ in pipeline.updateStabilizerEnabled() }
        .onChange(of: pipeline.fov) { _ in pipeline.updateFov() }
        .onChange(of: pipeline.distRatio) { _ in pipeline.updateDistRatio() }
        .onChange(of: pipeline.yaw) { _ in pipeline.updateYaw() }
        .onChange(of: pipeline.pitch) { _ in pipeline.updatePitch() }
        .onChange(of: pipeline.roll) { _ in pipeline.updateRoll() }
        .onChange(of: pipeline.yoloPadding) { _ in pipeline.updateYoloPadding() }
        .onChange(of: pipeline.yoloEnabled) { newValue in
            Config.yoloEnabled = newValue
        }
        .onChange(of: pipeline.yoloPreviewEnabled) { _ in pipeline.updateYoloPreviewEnabled() }
        .onChange(of: pipeline.yoloTargetFPS) { _ in pipeline.updateYoloTargetFPS() }
        .onChange(of: pipeline.previewEnabled) { newValue in
            Config.previewEnabled = newValue
        }
        .onChange(of: pipeline.trackTargetRatio) { _ in pipeline.updateTrackTargetRatio() }
        .onChange(of: pipeline.trackRecenterSpeed) { _ in pipeline.updateTrackRecenterSpeed() }
        .onChange(of: pipeline.streamManager.isStreaming) { streaming in
            if streaming {
                pipeline.debug.isDetailVisible = false
            }
        }
        .onDisappear {
            pipeline.stop()
        }
    }

    // MARK: - Preview

    private var previewSection: some View {
        ZStack(alignment: .topTrailing) {
            ZStack {
                if pipeline.stabEnabled, pipeline.camera.cameraAuthorized {
                    if let texture = pipeline.previewTexture {
                        MetalView(device: pipeline.device, texture: texture, previewEnabled: pipeline.previewEnabled)
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

                if pipeline.stabEnabled, pipeline.previewEnabled {
                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 10)
                                .onChanged { value in
                                    if !dragStarted {
                                        dragStarted = true
                                        gestureStartYaw = pipeline.yaw
                                        gestureStartPitch = pipeline.pitch
                                    }
                                    let dx = Float(value.translation.width)
                                    let dy = Float(value.translation.height)
                                    let sensitivity: Float = 0.3
                                    pipeline.yaw = clamp(gestureStartYaw - dx * sensitivity, -90, 90)
                                    pipeline.pitch = clamp(gestureStartPitch + dy * sensitivity, -90, 90)
                                }
                                .onEnded { _ in
                                    dragStarted = false
                                }
                        )
                        .simultaneousGesture(
                            RotationGesture()
                                .onChanged { angle in
                                    if !rotationStarted {
                                        rotationStarted = true
                                        gestureStartRoll = pipeline.roll
                                    }
                                    pipeline.roll = clamp(gestureStartRoll - Float(angle.degrees), -45, 45)
                                }
                                .onEnded { _ in
                                    rotationStarted = false
                                }
                        )
                        .simultaneousGesture(
                            TapGesture()
                                .onEnded { _ in
                                    withAnimation(.easeInOut(duration: 0.3)) {
                                        pipeline.yaw = 0
                                        pipeline.pitch = 0
                                        pipeline.roll = 0
                                    }
                                }
                        )
                }
            }

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

            if pipeline.yoloOverlayEnabled, pipeline.yoloEnabled {
                VStack {
                    Spacer()
                    HStack {
                        YOLOOverlayView(
                            debug: pipeline.debug,
                            device: pipeline.device,
                            texture: pipeline.stabTexture
                        )
                        .frame(maxWidth: UIScreen.main.bounds.width * 0.7, maxHeight: UIScreen.main.bounds.height * 0.5)
                        .padding(4)
                        Spacer()
                    }
                }
            }
        }
    }

    // MARK: - Control Panel

    private var controlPanel: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    panelExpanded.toggle()
                }
            } label: {
                HStack {
                    Text(panelExpanded ? selectedTab.rawValue : "Controls")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.white)
                    Spacer()
                    Image(systemName: panelExpanded ? "chevron.down" : "chevron.up")
                        .font(.caption2)
                        .foregroundColor(.gray)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.gray.opacity(0.2))
            }

            if panelExpanded {
                ScrollView(.vertical, showsIndicators: false) {
                    switch selectedTab {
                    case .camera: cameraTabContent
                    case .effects: effectsTabContent
                    case .stream: streamTabContent
                    }
                }
                .frame(maxHeight: 240)

                HStack {
                    ForEach(ControlTab.allCases, id: \.self) { tab in
                        Button {
                            selectedTab = tab
                        } label: {
                            VStack(spacing: 2) {
                                Image(systemName: tab.icon)
                                Text(tab.rawValue)
                                    .font(.system(size: 10))
                            }
                            .foregroundColor(selectedTab == tab ? .white : .gray)
                            .frame(maxWidth: .infinity)
                        }
                    }
                }
                .padding(.vertical, 8)
                .background(Color.black.opacity(0.3))
            }
        }
        .background(.ultraThinMaterial)
        .cornerRadius(10, corners: [.topLeft, .topRight])
    }

    // MARK: - Camera Tab

    private var cameraTabContent: some View {
        VStack(spacing: 8) {
            lensPicker
            shutterRow
            isoRow
            focusRow
            stabilizerToggleRow
        }
        .padding(12)
    }

    // MARK: - Effects Tab

    private var effectsTabContent: some View {
        VStack(spacing: 8) {
            fovRow
            distRatioRow
            yoloToggleRow
            yoloOverlayToggleRow
            yoloOverlayScaleRow

            Button {
                withAnimation {
                    advancedExpanded.toggle()
                }
            } label: {
                HStack {
                    Text("高级设置").font(.caption).foregroundColor(.gray)
                    Spacer()
                    Image(systemName: advancedExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2).foregroundColor(.gray)
                }
            }

            if advancedExpanded {
                VStack(spacing: 8) {
                    syncRow
                    yoloPaddingRow
                    yoloTargetFPSRow
                    trackTargetRatioRow
                    trackRecenterSpeedRow
                }
            }
        }
        .padding(12)
    }

    // MARK: - Stream Tab

    private var streamTabContent: some View {
        VStack(spacing: 8) {
            if !presets.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(presets) { preset in
                            Button {
                                rtmpUrl = preset.url
                                streamKey = preset.streamKey
                            } label: {
                                HStack(spacing: 4) {
                                    Text(preset.name)
                                        .font(.caption)
                                        .lineLimit(1)
                                    Button {
                                        presets.removeAll { $0.id == preset.id }
                                        Config.streamPresets = presets
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .font(.system(size: 12))
                                            .foregroundColor(.gray)
                                    }
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(Color.white.opacity(0.1))
                                .cornerRadius(8)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            Button {
                showAddPresetSheet = true
            } label: {
                HStack {
                    Image(systemName: "plus.circle")
                    Text("添加预设")
                }
                .font(.caption)
            }
            .sheet(isPresented: $showAddPresetSheet) {
                NavigationView {
                    Form {
                        TextField("名称", text: $newPresetName)
                        TextField("RTMP URL", text: $newPresetUrl)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        SecureField("Stream Key", text: $newPresetKey)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    }
                    .navigationTitle("添加预设")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("取消") { showAddPresetSheet = false }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("保存") {
                                let preset = StreamPreset(name: newPresetName, url: newPresetUrl, streamKey: newPresetKey)
                                presets.append(preset)
                                Config.streamPresets = presets
                                newPresetName = ""
                                newPresetUrl = ""
                                newPresetKey = ""
                                showAddPresetSheet = false
                            }
                            .disabled(newPresetName.isEmpty || newPresetUrl.isEmpty)
                        }
                    }
                }
            }

            rtmpUrlRow
            streamKeyRow
            resolutionRow
            bitrateRow
            streamButtonRow
        }
        .padding(12)
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
            Text("Preview").font(.caption2).foregroundColor(.gray)
            Toggle("", isOn: $pipeline.previewEnabled).labelsHidden()
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

    private var yoloToggleRow: some View {
        HStack {
            Text("YOLO").font(.caption).frame(width: 55, alignment: .leading)
            Toggle("", isOn: $pipeline.yoloEnabled).labelsHidden()
            Spacer()
            Button {
                pipeline.yoloPreviewEnabled.toggle()
                pipeline.updateYoloPreviewEnabled()
            } label: {
                Image(systemName: pipeline.yoloPreviewEnabled ? "eye.fill" : "eye.slash")
                    .font(.caption)
                    .foregroundColor(pipeline.yoloPreviewEnabled ? .cyan : .gray)
            }
            .disabled(!pipeline.yoloEnabled)
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

    private var yoloTargetFPSRow: some View {
        labeledRow("YFPS") {
            Slider(value: $pipeline.yoloTargetFPS, in: 10...60, step: 1)
        } valueLabel: {
            Text("\(Int(pipeline.yoloTargetFPS))").font(.caption).foregroundColor(.gray).frame(width: 40, alignment: .trailing)
        }
    }

    private var yoloOverlayToggleRow: some View {
        HStack {
            Text("YOLOOverlay").font(.caption).frame(width: 80, alignment: .leading)
            Toggle("", isOn: $pipeline.yoloOverlayEnabled)
                .labelsHidden()
                .onChange(of: pipeline.yoloOverlayEnabled) { _ in
                    pipeline.updateYoloOverlayEnabled()
                }
            Spacer()
            Text(pipeline.yoloOverlayEnabled ? "ON" : "OFF")
                .font(.caption2)
                .foregroundColor(pipeline.yoloOverlayEnabled ? .green : .red)
        }
    }

    private var yoloOverlayScaleRow: some View {
        labeledRow("Scale") {
            Slider(value: $pipeline.yoloOverlayScale, in: 0.3...1.2, step: 0.1)
        } valueLabel: {
            Text(String(format: "%.1fx", pipeline.yoloOverlayScale)).font(.caption).foregroundColor(.gray).frame(width: 40, alignment: .trailing)
        }
        .disabled(!pipeline.yoloOverlayEnabled)
        .onChange(of: pipeline.yoloOverlayScale) { _ in
            pipeline.updateYoloOverlayScale()
        }
    }

    private var trackTargetRatioRow: some View {
        labeledRow("TargetRatio") {
            Slider(value: $pipeline.trackTargetRatio, in: 0.1...1.0, step: 0.05)
        } valueLabel: {
            Text(String(format: "%.2f", pipeline.trackTargetRatio)).font(.caption).foregroundColor(.gray).frame(width: 40, alignment: .trailing)
        }
    }

    private var trackRecenterSpeedRow: some View {
        labeledRow("Recenter") {
            Slider(value: $pipeline.trackRecenterSpeed, in: 0.05...0.5, step: 0.01)
        } valueLabel: {
            Text(String(format: "%.2f", pipeline.trackRecenterSpeed)).font(.caption).foregroundColor(.gray).frame(width: 40, alignment: .trailing)
        }
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

    private func clamp(_ value: Float, _ min: Float, _ max: Float) -> Float {
        Swift.min(Swift.max(value, min), max)
    }

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
