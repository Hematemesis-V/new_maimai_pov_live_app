import SwiftUI
import simd
import CoreMedia
import Combine
import AVFoundation
import Metal
import QuartzCore
import UIKit

struct Phase2View: View {
    @StateObject private var camera = CameraCaptureManager()
    @State private var focusValue: Double = 0.5
    @State private var shutterTimescale: Double = 244.0
    @State private var isoValue: Double = 2000.0
    @State private var minISO: Double = 50.0
    @State private var maxISO: Double = 3200.0
    @State private var selectedLens: LensType = .main
    @State private var syncOffsetMs: Double = Config.defaultSyncOffsetMs
    @State private var readoutTimeMs: Double = Config.defaultReadoutTimeMs
    @State private var audioDelayMs: Double = 0.0

    // Stabilizer
    @State private var fov: Float = 100.0
    @State private var distRatio: Float = 0.0
    @State private var yaw: Float = 0.0
    @State private var pitch: Float = 0.0
    @State private var roll: Float = 0.0
    @State private var stabEnabled: Bool = true
    @State private var lagMs: Double = 0
    @State private var controlsExpanded: Bool = true

    @State private var frameCount: Int = 0
    @State private var currentFPS: Double = 0
    @State private var latestQuat: simd_quatf?
    private let fpsTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    @StateObject private var debug = DebugInfoManager.shared

    private let device = MTLCreateSystemDefaultDevice()!
    @State private var stabilizer: MetalStabilizer?

    var body: some View {
        VStack(spacing: 0) {
            // Preview
            previewSection
                .frame(maxHeight: .infinity)

            // Collapsible control card
            controlCard
        }
        .preferredColorScheme(.dark)
        .background(Color.black)
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            setupPipeline()
        }
        .onChange(of: selectedLens) { newLens in
            camera.switchLens(to: newLens)
            reconfigureLens()
            debug.lensType = newLens.rawValue
        }
        .onChange(of: focusValue) { camera.setFocus(Float($0)) }
        .onChange(of: shutterTimescale) { applyExposure() }
        .onChange(of: isoValue) { applyExposure() }
        .onChange(of: syncOffsetMs) { newVal in Config.syncOffsetMs = newVal }
        .onChange(of: readoutTimeMs) { newVal in Config.readoutTimeMs = newVal }
        .onChange(of: audioDelayMs) { camera.audioDelayMs = $0 }
        .onChange(of: stabEnabled) { newVal in
            stabilizer?.stabilizerEnabled = newVal
            debug.stabEnabled = newVal
        }
        .onChange(of: fov) { newVal in
            stabilizer?.fov = newVal
            debug.fov = newVal
        }
        .onChange(of: distRatio) { newVal in
            stabilizer?.distRatio = newVal
            debug.distRatio = newVal
        }
        .onChange(of: yaw) { stabilizer?.yaw = $0 }
        .onChange(of: pitch) { stabilizer?.pitch = $0 }
        .onChange(of: roll) { stabilizer?.roll = $0 }
        .onReceive(fpsTimer) { _ in
            currentFPS = Double(frameCount)
            debug.fps = Double(frameCount)
            debug.frameCount = frameCount
            frameCount = 0
            latestQuat = MotionManager.shared.latestQuaternion()
        }
        .onDisappear {
            camera.onVideoFrame = nil
            camera.stopRunning()
            MotionManager.shared.stopUpdates()
        }
    }

    // MARK: - Preview

    private var previewSection: some View {
        ZStack(alignment: .topTrailing) {
            if let stab = stabilizer, camera.cameraAuthorized {
                MetalView(device: device, texture: stab.outputTexture)
                    .aspectRatio(3.0 / 4.0, contentMode: .fit)
            } else if camera.cameraAuthorized {
                CameraPreviewView(session: camera.session)
                    .aspectRatio(3.0 / 4.0, contentMode: .fit)
            } else {
                Rectangle()
                    .fill(Color.black)
                    .aspectRatio(3.0 / 4.0, contentMode: .fit)
                    .overlay(Text("Camera not authorized").foregroundColor(.gray))
            }

            VStack(alignment: .trailing, spacing: 2) {
                Text("FPS: \(Int(currentFPS))")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(currentFPS >= 55 ? .green : .orange)
                Text("Lag: \(String(format: "%.1f", lagMs))ms")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.gray)
            }
            .padding(6)
            .background(Color.black.opacity(0.5))
            .cornerRadius(4)
            .padding(4)

            DebugOverlayView(debug: debug)
                .padding(.leading, 4)
                .padding(.top, 4)
        }
    }

    // MARK: - Control Card

    private var controlCard: some View {
        VStack(spacing: 0) {
            // Card header
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
        Picker("Lens", selection: $selectedLens) {
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
                shutterTimescale = 244.0; applyExposure()
            }
            .buttonStyle(.borderedProminent)
            .tint(shutterTimescale == 244.0 ? .orange : .gray)
            .controlSize(.small)
            .disabled(camera.exposureMode != .custom)

            Button("1/122") {
                shutterTimescale = 122.0; applyExposure()
            }
            .buttonStyle(.borderedProminent)
            .tint(shutterTimescale == 122.0 ? .orange : .gray)
            .controlSize(.small)
            .disabled(camera.exposureMode != .custom)

            Spacer()
            Button(camera.exposureMode == .custom ? "M" : "A") {
                camera.exposureMode == .custom
                    ? camera.setAutoExposure()
                    : camera.setCustomExposure()
            }
            .buttonStyle(.borderedProminent)
            .tint(camera.exposureMode == .custom ? .orange : .green)
            .controlSize(.small)
            .font(.caption2)
        }
    }

    private var isoRow: some View {
        labeledRow("ISO") {
            Slider(value: $isoValue, in: minISO...maxISO, step: 1)
        } valueLabel: {
            Text("\(Int(isoValue))").font(.caption).foregroundColor(.gray).frame(width: 40, alignment: .trailing)
        }
        .disabled(camera.exposureMode != .custom)
        .onChange(of: camera.isRunning) { running in
            if running { updateISORange() }
        }
    }

    private var focusRow: some View {
        labeledRow("Focus") {
            Slider(value: $focusValue, in: 0...1)
        } valueLabel: {
            Text(String(format: "%.2f", focusValue)).font(.caption).foregroundColor(.gray).frame(width: 40, alignment: .trailing)
        }
    }

    private var stabilizerToggleRow: some View {
        HStack {
            Text("Stabilizer").font(.caption).frame(width: 55, alignment: .leading)
            Toggle("", isOn: $stabEnabled).labelsHidden()
            Spacer()
            Text("Lag: \(String(format: "%.1f", lagMs))ms")
                .font(.caption2).foregroundColor(.gray)
        }
    }

    private var fovRow: some View {
        labeledRow("FOV") {
            Slider(value: Binding(get: { Double(fov) }, set: { fov = Float($0) }), in: 30...160, step: 1)
        } valueLabel: {
            Text("\(Int(fov))°").font(.caption).foregroundColor(.gray).frame(width: 40, alignment: .trailing)
        }
    }

    private var distRatioRow: some View {
        labeledRow("Dist") {
            Slider(value: Binding(get: { Double(distRatio) }, set: { distRatio = Float($0) }), in: 0...1)
        } valueLabel: {
            Text(String(format: "%.2f", distRatio)).font(.caption).foregroundColor(.gray).frame(width: 40, alignment: .trailing)
        }
    }

    private var yawPitchRollRow: some View {
        VStack(spacing: 4) {
            labeledRow("Yaw") {
                Slider(value: Binding(get: { Double(yaw) }, set: { yaw = Float($0) }), in: -30...30)
            } valueLabel: {
                Text(String(format: "%.1f", yaw)).font(.caption).foregroundColor(.gray).frame(width: 40, alignment: .trailing)
            }
            labeledRow("Pitch") {
                Slider(value: Binding(get: { Double(pitch) }, set: { pitch = Float($0) }), in: -30...30)
            } valueLabel: {
                Text(String(format: "%.1f", pitch)).font(.caption).foregroundColor(.gray).frame(width: 40, alignment: .trailing)
            }
            labeledRow("Roll") {
                Slider(value: Binding(get: { Double(roll) }, set: { roll = Float($0) }), in: -15...15)
            } valueLabel: {
                Text(String(format: "%.1f", roll)).font(.caption).foregroundColor(.gray).frame(width: 40, alignment: .trailing)
            }
        }
    }

    private var syncRow: some View {
        Group {
            labeledRow("Sync") {
                Slider(value: $syncOffsetMs, in: -50...50)
            } valueLabel: {
                Text(String(format: "%.0f", syncOffsetMs)).font(.caption).foregroundColor(.gray).frame(width: 40, alignment: .trailing)
            }
            labeledRow("Readout") {
                Slider(value: $readoutTimeMs, in: 5...15)
            } valueLabel: {
                Text(String(format: "%.1f", readoutTimeMs)).font(.caption).foregroundColor(.gray).frame(width: 40, alignment: .trailing)
            }
        }
    }

    private var audioDelayRow: some View {
        labeledRow("AudioDel") {
            Slider(value: $audioDelayMs, in: -200...200)
        } valueLabel: {
            Text("\(Int(audioDelayMs))ms").font(.caption).foregroundColor(.gray).frame(width: 40, alignment: .trailing)
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

    private func setupPipeline() {
        let lensCfg = LensCalibration.config(for: selectedLens, inputWidth: Config.inputWidth)
        let stab = MetalStabilizer(device: device, lensConfig: lensCfg)
        stab?.stabilizerEnabled = stabEnabled
        stab?.fov = fov
        self.stabilizer = stab

        debug.fov = fov
        debug.distRatio = distRatio
        debug.stabEnabled = stabEnabled
        debug.lensType = selectedLens.rawValue
        debug.log("Pipeline initialized: \(selectedLens.rawValue)")

        camera.checkPermissionAndStart()
        camera.setFocus(Float(focusValue))
        MotionManager.shared.startUpdates()

        camera.onVideoFrame = { [weak camera] pixelBuffer, alignedTime in
            frameCount += 1
            guard let stab = stabilizer, stab.stabilizerEnabled else { return }

            let centerTime = alignedTime + (Config.syncOffsetMs / 1000.0)
            let topTime    = centerTime - (Config.readoutTimeMs / 2000.0)
            let bottomTime = centerTime + (Config.readoutTimeMs / 2000.0)

            guard let qCenter = MotionManager.shared.getQuaternion(at: centerTime),
                  let qTop    = MotionManager.shared.getQuaternion(at: topTime),
                  let qBottom = MotionManager.shared.getQuaternion(at: bottomTime) else { return }

            let start = CACurrentMediaTime()
            stab.process(pixelBuffer: pixelBuffer, qCenter: qCenter, qTop: qTop, qBottom: qBottom)
            let elapsed = CACurrentMediaTime() - start
            DispatchQueue.main.async {
                lagMs = elapsed * 1000.0
                debug.stabLagMs = elapsed * 1000.0
            }
        }

        camera.onAudioSample = { _ in }
    }

    private func applyExposure() {
        guard camera.exposureMode == .custom else { return }
        camera.setExposure(duration: CMTime(value: 1, timescale: Int32(shutterTimescale)), iso: Float(isoValue))
    }

    private func updateISORange() {
        let actualMin = Double(camera.getMinISO()), actualMax = Double(camera.getMaxISO())
        guard actualMin > 0, actualMax > actualMin else { return }
        minISO = actualMin; maxISO = actualMax
        if isoValue < actualMin || isoValue > actualMax { isoValue = actualMin }
    }

    private func reconfigureLens() {
        let cfg = LensCalibration.config(for: selectedLens, inputWidth: Config.inputWidth)
        stabilizer?.loadLensConfig(cfg)
        fov = cfg.defaultFov
        stabilizer?.fov = cfg.defaultFov
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
