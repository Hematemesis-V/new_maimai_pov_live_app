import CoreMedia
import SwiftUI

struct ContentView: View {
    @StateObject private var cameraManager = CameraManager()
    @State private var focusValue: Double = 0.5
    @State private var syncOffset: Double = -25.0
    @State private var readoutTimeMs: Double = 9.18
    @State private var selectedLens: CameraManager.LensType = .main
    @State private var frameCounter = 0
    @State private var shutterTimescale: Double = 244.0
    @State private var isoValue: Double = 50.0
    @State private var minISO: Double = 50.0
    @State private var maxISO: Double = 3200.0

    var body: some View {
        VStack(spacing: 12) {
            headerView
            previewSection
            lensPicker
            focusSlider
            shutterSlider
            isoSlider
            syncOffsetSlider
            readoutSlider
            actionButtons
        }
        .preferredColorScheme(.dark)
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            setupCamera()
        }
        .onChange(of: cameraManager.isRunning) { isRunning in
            if isRunning {
                let actualMin = Double(cameraManager.getMinISO())
                let actualMax = Double(cameraManager.getMaxISO())
                
                // 加上安全判断，确保区间合法，彻底杜绝 Slider 崩溃
                if actualMin > 0 && actualMax > actualMin {
                    minISO = actualMin
                    maxISO = actualMax
                    // 如果当前的 isoValue 不在合法范围内，重置为最小值
                    if isoValue < actualMin || isoValue > actualMax {
                        isoValue = actualMin
                    }
                }
            }
        }
        .onChange(of: focusValue) { newValue in
            cameraManager.setFocus(Float(newValue))
        }
        .onChange(of: shutterTimescale) { newValue in
            if cameraManager.exposureMode == .custom {
                let duration = CMTime(value: 1, timescale: Int32(newValue))
                cameraManager.setExposure(duration: duration, iso: Float(isoValue))
            }
        }
        .onChange(of: isoValue) { newValue in
            if cameraManager.exposureMode == .custom {
                let duration = CMTime(value: 1, timescale: Int32(shutterTimescale))
                cameraManager.setExposure(duration: duration, iso: Float(newValue))
            }
        }
        .onChange(of: syncOffset) { newValue in
            AppSyncConfig.syncOffsetMs = newValue
        }
        .onDisappear {
            cameraManager.onFrame = nil
            cameraManager.stopRunning()
            MotionManager.shared.stopUpdates()
        }
    }

    private var headerView: some View {
        Text("Maimai POV Stabilizer")
            .font(.headline)
            .foregroundColor(.cyan)
    }

    private var previewSection: some View {
        Group {
            if cameraManager.cameraAuthorized {
                ZStack(alignment: .topTrailing) {
                    CameraPreviewView(session: cameraManager.session)
                        .aspectRatio(3.0 / 4.0, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 8))

                    if cameraManager.isRecording {
                        recIndicator
                    }
                }
            } else {
                Rectangle()
                    .fill(Color.black)
                    .aspectRatio(3.0 / 4.0, contentMode: .fit)
                    .overlay(
                        Text("Camera Not Authorized")
                            .foregroundColor(.gray)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private var recIndicator: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Color.red)
                .frame(width: 10, height: 10)
            Text("REC")
                .font(.caption2)
                .fontWeight(.bold)
                .foregroundColor(.red)
        }
        .padding(8)
        .background(Color.black.opacity(0.5))
        .clipShape(Capsule())
        .padding(8)
    }

    private var lensPicker: some View {
        Picker("Lens", selection: $selectedLens) {
            ForEach(CameraManager.LensType.allCases, id: \.self) { lens in
                Text(lens.rawValue).tag(lens)
            }
        }
        .pickerStyle(SegmentedPickerStyle())
        .padding(.horizontal)
        .onChange(of: selectedLens) { newLens in
            cameraManager.switchLens(to: newLens)
        }
    }

    private var focusSlider: some View {
        VStack(alignment: .leading) {
            Text("Focus: \(focusValue, specifier: "%.2f")")
            Slider(value: $focusValue, in: 0.0...1.0)
        }
        .padding(.horizontal)
    }

    private var shutterSlider: some View {
        VStack(alignment: .leading) {
            HStack {
                Text("Shutter: 1/\(Int(shutterTimescale))")
                Spacer()
                Button(cameraManager.exposureMode == .custom ? "Auto" : "Manual") {
                    if cameraManager.exposureMode == .custom {
                        cameraManager.setAutoExposure()
                    } else {
                        cameraManager.setCustomExposure()
                    }
                }
                .font(.caption)
                .buttonStyle(.borderedProminent)
                .tint(cameraManager.exposureMode == .custom ? .orange : .green)
            }
            HStack {
                Button("1/244") {
                    shutterTimescale = 244.0
                }
                .buttonStyle(.borderedProminent)
                .tint(shutterTimescale == 244.0 ? .blue : .gray)
                .disabled(cameraManager.exposureMode != .custom)
                
                Button("1/122") {
                    shutterTimescale = 122.0
                }
                .buttonStyle(.borderedProminent)
                .tint(shutterTimescale == 122.0 ? .blue : .gray)
                .disabled(cameraManager.exposureMode != .custom)
            }
            .opacity(cameraManager.exposureMode == .custom ? 1.0 : 0.4)
        }
        .padding(.horizontal)
    }

    private var isoSlider: some View {
        VStack(alignment: .leading) {
            Text("ISO: \(Int(isoValue))")
            Slider(value: $isoValue, in: minISO...maxISO, step: 1)
                .disabled(cameraManager.exposureMode != .custom)
                .opacity(cameraManager.exposureMode == .custom ? 1.0 : 0.4)
        }
        .padding(.horizontal)
    }

    private var syncOffsetSlider: some View {
        VStack(alignment: .leading) {
            Text("Sync Offset (ms): \(syncOffset, specifier: "%.1f")")
            Slider(value: $syncOffset, in: -50.0...50.0)
        }
        .padding(.horizontal)
    }

    private var readoutSlider: some View {
        VStack(alignment: .leading) {
            Text("Readout Time (ms): \(readoutTimeMs, specifier: "%.2f")")
            Slider(value: $readoutTimeMs, in: 5.0...15.0)
        }
        .padding(.horizontal)
    }

    private var actionButtons: some View {
        HStack {
            Button(cameraManager.awbLocked ? "Unlock AWB" : "Lock AWB") {
                if cameraManager.awbLocked {
                    cameraManager.unlockWhiteBalance()
                } else {
                    cameraManager.lockWhiteBalance()
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(cameraManager.awbLocked ? .red : .blue)

            Spacer()

            Button(cameraManager.isRecording ? "Stop Rec" : "Rec") {
                if cameraManager.isRecording {
                    cameraManager.stopRecording()
                } else {
                    cameraManager.startRecording()
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(cameraManager.isRecording ? .red : .gray)
        }
        .padding(.horizontal)
    }

    private func setupCamera() {
        cameraManager.checkPermissionAndStart()
        cameraManager.setFocus(Float(focusValue))
        MotionManager.shared.startUpdates()


        cameraManager.onFrame = { pixelBuffer, alignedFrameTime in

            // 性能限制，每2帧发送1帧
            //frameCounter += 1
            //if frameCounter % 2 != 0 { return }

            let centerTime = alignedFrameTime + (syncOffset / 1000.0)
            let topTime = centerTime - (readoutTimeMs / 2000.0)
            let bottomTime = centerTime + (readoutTimeMs / 2000.0)

            if let topQuat = MotionManager.shared.getQuaternion(at: topTime),
               let centerQuat = MotionManager.shared.getQuaternion(at: centerTime),
               let bottomQuat = MotionManager.shared.getQuaternion(at: bottomTime) {

                NetworkManager.shared.sendFrame(
                    buffer: pixelBuffer,
                    frameTimestamp: centerTime,
                    topQuat: topQuat,
                    centerQuat: centerQuat,
                    bottomQuat: bottomQuat
                )
            }
        }
    }
}
