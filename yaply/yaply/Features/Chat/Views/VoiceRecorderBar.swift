import SwiftUI

/// Replaces `MessageInputView` in `ChatView` while a voice message is being
/// recorded. Cancel discards; send hands the finished file URL to the caller.
struct VoiceRecorderBar: View {
    let onCancel: () -> Void
    let onSend: (URL, TimeInterval) -> Void

    @State private var recorder = AudioRecorderService()

    var body: some View {
        HStack(spacing: 14) {
            Button {
                recorder.cancel()
                onCancel()
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 18))
                    .foregroundStyle(Color.yaplyDanger)
                    .frame(width: 36, height: 36)
            }

            HStack(spacing: 8) {
                Circle()
                    .fill(Color.yaplyDanger)
                    .frame(width: 9, height: 9)
                    .opacity(recorder.isRecording ? 1 : 0.3)
                    .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: recorder.isRecording)

                Text(timeString(recorder.elapsed))
                    .font(.system(size: 15, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.yaplyPrimary)

                LevelMeter(level: recorder.level)
                    .frame(height: 20)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                if let url = recorder.stop() {
                    onSend(url, recorder.elapsed)
                } else {
                    onCancel()
                }
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(Color.yaplyAccent)
                    .clipShape(Circle())
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.yaplySurface)
        .overlay(Rectangle().fill(Color.yaplyBorder).frame(height: 1), alignment: .top)
        .task {
            await recorder.start()
        }
        .onChange(of: recorder.permissionDenied) { _, denied in
            if denied { onCancel() }
        }
    }

    private func timeString(_ t: TimeInterval) -> String {
        let total = Int(t)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

private struct LevelMeter: View {
    let level: CGFloat

    var body: some View {
        GeometryReader { geo in
            let count = 18
            HStack(spacing: 3) {
                ForEach(0..<count, id: \.self) { i in
                    Capsule()
                        .fill(Color.yaplyAccent.opacity(0.8))
                        .frame(height: barHeight(i, count: count, maxHeight: geo.size.height))
                }
            }
            .frame(maxHeight: .infinity, alignment: .center)
        }
    }

    private func barHeight(_ i: Int, count: Int, maxHeight: CGFloat) -> CGFloat {
        // A gentle pseudo-waveform: center bars taller, scaled by the live level.
        let dist = abs(CGFloat(i) - CGFloat(count) / 2) / (CGFloat(count) / 2)
        let base = (1 - dist * 0.7)
        return max(3, maxHeight * base * max(0.15, level))
    }
}
