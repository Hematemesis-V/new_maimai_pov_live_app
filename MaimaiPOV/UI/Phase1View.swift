import SwiftUI
import simd
import CoreMedia
import Combine
import AVFoundation

struct Phase1View: View {
    @StateObject private var camera = CameraCaptureManager()
    @State private var focusValue: Double = 0.5
    @State private var shutterTimescale: Double = 244.0
    @State private var isoValue: Double = 2000.0
    @State private var minISO: Double = 50.0
    @State private var maxISO: Double = 3200.0
    @State private var selectedLens: LensType = .main
    @State private var syncOffsetMs: Double = Config.syncOffsetMs
    @State private var readoutTimeMs: Double = Config.readoutTimeMs
    @State private var audioDelayMs: Double = Config.audioDelayMs

    @State private var frameCount: Int = 0
    @State private var currentFPS: Double = 0
    @State private var latestQuat: simd_quatf?
    private let fpsTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 8) {
            headerView
            previewSection
            lensPicker
            focusSlider
            shutterPicker
            isoSlider
            syncOffsetSlider
            readoutSlider
            audioDelaySlider
            imuStatus
            actionButtons
        }
        .preferredColorScheme(.dark)
        .padding(.horizontal, 8)
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            setupPipeline()
        }
        .onChange(of: selectedLens) { newLens in camera.switchLens(to: newLens) }
        .onChange(of: focusValue) { camera.setFocus(Float($0)) }
        .onChange(of: shutterTimescale) { applyExposure() }
        .onChange(of: isoValue) { applyExposure() }
        .onChange(of: syncOffsetMs) { newVal in Config.syncOffsetMs = newVal }
        .onChange(of: readoutTimeMs) { newVal in Config.readoutTimeMs = newVal }
        .onChange(of: audioDelayMs) { Config.audioDelayMs = $0 }
        .onReceive(fpsTimer) { _ in
            currentFPS = Double(frameCount)
            frameCount = 0
            latestQuat = MotionManager.shared.latestQuaternion()
        }
        .onDisappear {
            camera.onVideoFrame = nil
            camera.stopRunning()
            MotionManager.shared.stopUpdates()
        }
    }

    // MARK: - Subviews

    private var headerView: some View {
        HStack {
            Text("Maimai POV — Phase 1")
                .font(.headline)
                .foregroundColor(.cyan)
            Spacer()
            Text("FPS: \(Int(currentFPS))")
                .font(.caption)
                .foregroundColor(currentFPS >= 55 ? .green : .orange)
        }
    }

    private var previewSection: some View {
        Group {
            if camera.cameraAuthorized {
                CameraPreviewView(session: camera.session)
                    .aspectRatio(3.0 / 4.0, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                Rectangle()
                    .fill(Color.black)
                    .aspectRatio(3.0 / 4.0, contentMode: .fit)
                    .overlay(Text("Camera not authorized").foregroundColor(.gray))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private var lensPicker: some View {
        Picker("Lens", selection: $selectedLens) {
            ForEach(LensType.allCases, id: \.self) { lens in
                Text(lens.rawValue).tag(lens)
            }
        }
        .pickerStyle(.segmented)
    }

    private var focusSlider: some View {
        labeledSlider("Focus", value: $focusValue, range: 0...1, format: "%.2f")
    }

    private var shutterPicker: some View {
        HStack {
            Text("Shutter:").font(.caption)
            Spacer()
            Button("1/244") {
                shutterTimescale = 244.0
                applyExposure()
            }
            .buttonStyle(.borderedProminent)
            .tint(shutterTimescale == 244.0 ? .orange : .gray)
            .disabled(camera.exposureMode != .custom)

            Button("1/122") {
                shutterTimescale = 122.0
                applyExposure()
            }
            .buttonStyle(.borderedProminent)
            .tint(shutterTimescale == 122.0 ? .orange : .gray)
            .disabled(camera.exposureMode != .custom)

            Spacer()
            Button(camera.exposureMode == .custom ? "Manual" : "Auto") {
                if camera.exposureMode == .custom {
                    camera.setAutoExposure()
                } else {
                    camera.setCustomExposure()
                }
            }
            .font(.caption2)
            .buttonStyle(.borderedProminent)
            .tint(camera.exposureMode == .custom ? .orange : .green)
        }
    }

    private var isoSlider: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("ISO: \(Int(isoValue))").font(.caption)
            Slider(value: $isoValue, in: minISO...maxISO, step: 1)
                .disabled(camera.exposureMode != .custom)
        }
        .onChange(of: camera.isRunning) { running in
            if running { updateISORange() }
        }
    }

    private var syncOffsetSlider: some View {
        labeledSlider("Sync Offset (ms)", value: $syncOffsetMs, range: -50...50, format: "%.1f")
    }

    private var readoutSlider: some View {
        labeledSlider("Readout Time (ms)", value: $readoutTimeMs, range: 5...15, format: "%.2f")
    }

    private var audioDelaySlider: some View {
        labeledSlider("Audio Delay (ms)", value: $audioDelayMs, range: -200...200, format: "%.0f")
    }

    private var imuStatus: some View {
        HStack {
            if let q = latestQuat {
                Text(String(format: "IMU: w=%.3f x=%.3f y=%.3f z=%.3f", q.vector.w, q.vector.x, q.vector.y, q.vector.z))
            } else {
                Text("IMU: waiting...")
            }
        }
        .font(.system(size: 9, design: .monospaced))
        .foregroundColor(.gray)
    }

    private var actionButtons: some View {
        HStack {
            Button(camera.awbLocked ? "Unlock AWB" : "Lock AWB") {
                camera.awbLocked ? camera.unlockWhiteBalance() : camera.lockWhiteBalance()
            }
            .buttonStyle(.borderedProminent)
            .tint(camera.awbLocked ? .red : .blue)
            Spacer()
            Button(camera.isRunning ? "Stop" : "Start") {
                if camera.isRunning { camera.stopRunning() } else { camera.startRunning() }
            }
            .buttonStyle(.borderedProminent)
            .tint(camera.isRunning ? .red : .green)
        }
    }

    // MARK: - Helpers

    private func labeledSlider(_ label: String, value: Binding<Double>, range: ClosedRange<Double>, format: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(label): \(String(format: format, value.wrappedValue))").font(.caption)
            Slider(value: value, in: range) { _ in }
        }
    }

    private func setupPipeline() {
        camera.checkPermissionAndStart()
        camera.setFocus(Float(focusValue))
        MotionManager.shared.startUpdates()

        camera.onVideoFrame = { [weak camera] pixelBuffer, alignedTime in
            frameCount += 1
            // In Phase 1, video frames go directly to preview (via AVCaptureVideoPreviewLayer).
            // The alignedTime is available for IMU sync in later phases.
        }

        camera.onAudioSample = { sampleBuffer, alignedTime in
            // Audio is captured but not processed until Phase 4 (RTMP).
        }
    }

    private func applyExposure() {
        guard camera.exposureMode == .custom else { return }
        let duration = CMTime(value: 1, timescale: Int32(shutterTimescale))
        camera.setExposure(duration: duration, iso: Float(isoValue))
    }

    private func updateISORange() {
        let actualMin = Double(camera.getMinISO())
        let actualMax = Double(camera.getMaxISO())
        guard actualMin > 0, actualMax > actualMin else { return }
        minISO = actualMin
        maxISO = actualMax
        if isoValue < actualMin || isoValue > actualMax {
            isoValue = actualMin
        }
    }
}

// MARK: - AVCaptureVideoPreviewLayer wrapper

private final class PreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
}

private struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        view.previewLayer.connection?.videoOrientation = .portrait
        view.backgroundColor = .black
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}
}
