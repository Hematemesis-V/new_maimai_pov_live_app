import SwiftUI

struct DebugOverlayView: View {
    @ObservedObject var debug: DebugInfoManager
    @State private var isCollapsed = false
    @State private var dragOffset: CGSize = .zero
    @State private var showLog = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerBar

            if !isCollapsed {
                infoContent
                if showLog {
                    logSection
                }
            }
        }
        .font(.system(size: 10, design: .monospaced))
        .foregroundColor(.white)
        .background(Color.black.opacity(0.75))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.white.opacity(0.2), lineWidth: 0.5)
        )
        .offset(dragOffset)
        .gesture(dragGesture)
    }

    private var headerBar: some View {
        HStack(spacing: 6) {
            Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                .font(.system(size: 8, weight: .bold))
                .foregroundColor(.cyan)

            Text("DEBUG")
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(.cyan)

            Spacer()

            Text("\(Int(debug.fps))fps")
                .foregroundColor(debug.fps >= 55 ? .green : .orange)

            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    showLog.toggle()
                }
            } label: {
                Image(systemName: showLog ? "list.bullet.rectangle" : "list.bullet")
                    .font(.system(size: 9))
                    .foregroundColor(showLog ? .cyan : .gray)
            }

            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    isCollapsed.toggle()
                }
            } label: {
                Image(systemName: "minus")
                    .font(.system(size: 9))
                    .foregroundColor(.gray)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.black.opacity(0.5))
    }

    private var infoContent: some View {
        VStack(alignment: .leading, spacing: 2) {
            sectionHeader("STAB")
            infoRow("Lag", String(format: "%.1fms", debug.stabLagMs))
            infoRow("FOV", String(format: "%.0f°", debug.fov))
            infoRow("Dist", String(format: "%.2f", debug.distRatio))
            infoRow("Lens", debug.lensType)
            infoRow("Stab", debug.stabEnabled ? "ON" : "OFF",
                    color: debug.stabEnabled ? .green : .red)
            infoRow("Frame", "\(debug.frameCount)")

            Divider().background(Color.white.opacity(0.2)).padding(.vertical, 2)

            sectionHeader("YOLO")
            infoRow("Detect", debug.yoloDetected ? "YES" : "NO",
                    color: debug.yoloDetected ? .green : .red)
            infoRow("Conf", String(format: "%.2f", debug.yoloConfidence))
            infoRow("Infer", String(format: "%.1fms", debug.yoloInferenceMs))
            infoRow("Prep", String(format: "%.1fms", debug.yoloPreprocessMs))
            infoRow("Pad", "\(debug.yoloPadding)px")
            infoRow("Raw", debug.yoloRawCoord)
            infoRow("Stab", debug.yoloStabCoord)
            infoRow("Boxes", debug.yoloBoxesInfo)
            infoRow("Top3", debug.yoloTopBoxes)
            infoRow("Rank", "\(debug.yoloBestRank)", color: debug.yoloBestRank == 1 ? .green : .orange)
            infoRow("U", debug.yoloUniforms)

            Divider().background(Color.white.opacity(0.2)).padding(.vertical, 2)

            sectionHeader("TRACK")
            infoRow("State", debug.trackState,
                    color: debug.trackState == "tracking" ? .green : .orange)
            infoRow("Smooth", String(format: "%.0f,%.0f,%.0f,%.0f",
                debug.trackSmoothCx, debug.trackSmoothCy,
                debug.trackSmoothW, debug.trackSmoothH))
            infoRow("Crop", String(format: "%.0f×%.0f @%.0f,%.0f",
                debug.trackCropW, debug.trackCropH,
                debug.trackCx, debug.trackCy))
            infoRow("Alpha", String(format: "%.2f", debug.trackAlpha))
            infoRow("MaxSpd", String(format: "%.1f", debug.trackMaxSpeed))
            infoRow("Dead", String(format: "%.1f", debug.trackDeadZone))
            infoRow("Ratio", String(format: "%.2f", debug.trackTargetRatio))

            Divider().background(Color.white.opacity(0.2)).padding(.vertical, 2)

            sectionHeader("STREAM")
            infoRow("Readback", debug.streamInfo,
                    color: debug.streamInfo != "--" ? .green : .gray)

            Divider().background(Color.white.opacity(0.2)).padding(.vertical, 2)

            sectionHeader("RTMP")
            infoRow("Status", debug.rtmpStatus,
                    color: rtmpStatusColor(debug.rtmpStatus))
            infoRow("Bitrate", "\(debug.rtmpBitrate)kbps")
            infoRow("Dropped", "\(debug.rtmpDroppedFrames)frames")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    private var logSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider().background(Color.white.opacity(0.2))
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(debug.logMessages.indices, id: \.self) { i in
                            Text(debug.logMessages[i])
                                .font(.system(size: 8, design: .monospaced))
                                .foregroundColor(.green.opacity(0.8))
                                .id(i)
                        }
                    }
                }
                .frame(maxHeight: 120)
                .onChange(of: debug.logMessages.count) { count in
                    if count > 0 {
                        withAnimation {
                            proxy.scrollTo(count - 1, anchor: .bottom)
                        }
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 9, weight: .bold))
            .foregroundColor(.cyan)
    }

    private func infoRow(_ label: String, _ value: String, color: Color = .white) -> some View {
        HStack(spacing: 4) {
            Text(label + ":")
                .foregroundColor(.gray)
            Text(value)
                .foregroundColor(color)
            Spacer()
        }
    }

    private func rtmpStatusColor(_ status: String) -> Color {
        switch status {
        case "Publishing": return .green
        case "Connecting", "Connected": return .yellow
        case "Idle": return .gray
        default: return .red
        }
    }

    private var dragGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                dragOffset = value.translation
            }
            .onEnded { _ in
                dragOffset = .zero
            }
    }
}
