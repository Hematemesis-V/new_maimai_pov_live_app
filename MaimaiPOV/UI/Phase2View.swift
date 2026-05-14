import SwiftUI
import simd
import CoreMedia
import CoreImage
import Combine
import AVFoundation
import Metal
import QuartzCore
import UIKit

struct Phase2View: View {
    @StateObject private var pipeline = LivePipelineManager()
    @State private var controlsExpanded: Bool = true

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
        .onChange(of: pipeline.selectedLens) { newLens in
            pipeline.camera.switchLens(to: newLens)
            reconfigureLens()
            pipeline.debug.lensType = newLens.rawValue
        }
        .onChange(of: pipeline.focusValue) { pipeline.camera.setFocus(Float($0)) }
        .onChange(of: pipeline.shutterTimescale) { applyExposure() }
        .onChange(of: pipeline.isoValue) { applyExposure() }
        .onChange(of: pipeline.syncOffsetMs) { newVal in Config.syncOffsetMs = newVal }
        .onChange(of: pipeline.readoutTimeMs) { newVal in Config.readoutTimeMs = newVal }
        .onChange(of: pipeline.audioDelayMs) { pipeline.camera.audioDelayMs = $0 }
        .onChange(of: pipeline.stabEnabled) { newVal in
            pipeline.stabilizer?.stabilizerEnabled = newVal
            pipeline.debug.stabEnabled = newVal
        }
        .onChange(of: pipeline.fov) { newVal in
            pipeline.stabilizer?.fov = newVal
            pipeline.debug.fov = newVal
        }
        .onChange(of: pipeline.distRatio) { newVal in
            pipeline.stabilizer?.distRatio = newVal
            pipeline.debug.distRatio = newVal
        }
        .onChange(of: pipeline.yaw) { pipeline.stabilizer?.yaw = $0 }
        .onChange(of: pipeline.pitch) { pipeline.stabilizer?.pitch = $0 }
        .onChange(of: pipeline.roll) { pipeline.stabilizer?.roll = $0 }
        .onChange(of: pipeline.yoloPadding) { newVal in
            let pad = Int(newVal)
            Config.yoloPadding = pad
            pipeline.yoloDetector?.updatePadding(pad)
            pipeline.debug.yoloPadding = pad
            let u = YOLOPreprocessUniforms(padding: pad)
            pipeline.debug.yoloUniforms = String(format: "s%.3f pH%.0f pV%.0f pL%.0f pT%.0f",
                u.scale, u.padH, u.padV, u.padLeft, u.padTop)
        }
        .onChange(of: pipeline.trackAlpha) { newVal in
            pipeline.smoothTracker.alpha = Float(newVal)
            pipeline.debug.trackAlpha = Float(newVal)
        }
        .onChange(of: pipeline.trackMaxSpeed) { newVal in
            pipeline.smoothTracker.maxSpeed = Float(newVal)
            pipeline.debug.trackMaxSpeed = Float(newVal)
        }
        .onChange(of: pipeline.trackDeadZone) { newVal in
            pipeline.smoothTracker.deadZone = Float(newVal)
            pipeline.debug.trackDeadZone = Float(newVal)
        }
        .onChange(of: pipeline.trackTargetRatio) { newVal in
            pipeline.smoothTracker.targetRatio = Float(newVal)
            pipeline.debug.trackTargetRatio = Float(newVal)
        }
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
                        .aspectRatio(pipeline.cropRenderer != nil ? 9.0 / 16.0 : 3.0 / 4.0, contentMode: .fit)
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
                pipeline.shutterTimescale = 244.0; applyExposure()
            }
            .buttonStyle(.borderedProminent)
            .tint(pipeline.shutterTimescale == 244.0 ? .orange : .gray)
            .controlSize(.small)
            .disabled(pipeline.camera.exposureMode != .custom)

            Button("1/122") {
                pipeline.shutterTimescale = 122.0; applyExposure()
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
            if running { updateISORange() }
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

    private func applyExposure() {
        guard pipeline.camera.exposureMode == .custom else { return }
        pipeline.camera.setExposure(duration: CMTime(value: 1, timescale: Int32(pipeline.shutterTimescale)), iso: Float(pipeline.isoValue))
    }

    private func updateISORange() {
        let actualMin = Double(pipeline.camera.getMinISO()), actualMax = Double(pipeline.camera.getMaxISO())
        guard actualMin > 0, actualMax > actualMin else { return }
        pipeline.minISO = actualMin; pipeline.maxISO = actualMax
        if pipeline.isoValue < actualMin || pipeline.isoValue > actualMax { pipeline.isoValue = actualMin }
    }

    private func reconfigureLens() {
        let cfg = LensCalibration.config(for: pipeline.selectedLens, inputWidth: Config.inputWidth)
        pipeline.stabilizer?.loadLensConfig(cfg)
        pipeline.fov = cfg.defaultFov
        pipeline.stabilizer?.fov = cfg.defaultFov
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
