import AVFoundation
import SwiftUI

/// Playback bubble for a `type: "voice"` message. Streams the `.m4a` from the
/// `media` bucket URL with a play/pause control and a scrubbable progress track.
struct VoiceMessageBubble: View {
    let url: URL
    let isOwn: Bool

    @State private var player: AVPlayer?
    @State private var isPlaying = false
    @State private var progress: Double = 0
    @State private var duration: Double = 0
    @State private var observer: Any?

    private var tint: Color { isOwn ? .white : Color.yaplyAccent }

    var body: some View {
        HStack(spacing: 10) {
            Button(action: toggle) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(isOwn ? Color.yaplyAccent : .white)
                    .frame(width: 32, height: 32)
                    .background(isOwn ? Color.white : Color.yaplyAccent)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 4) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(tint.opacity(0.3))
                        Capsule()
                            .fill(tint)
                            .frame(width: max(3, geo.size.width * progress))
                    }
                }
                .frame(height: 4)

                Text(timeString(displayTime))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(isOwn ? Color.white.opacity(0.85) : Color.yaplySecondary)
            }
            .frame(width: 140)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            Group {
                if isOwn {
                    LinearGradient(
                        colors: [Color.yaplyAccent, Color.yaplyAccentDark],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                } else {
                    Color.yaplyCard
                }
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(isOwn ? Color.clear : Color.yaplyBorderSoft, lineWidth: 1)
        )
        .onDisappear(perform: teardown)
    }

    private var displayTime: Double {
        if duration > 0 { return progress * duration }
        return 0
    }

    private func toggle() {
        if player == nil { setup() }
        guard let player else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            if progress >= 0.999 { player.seek(to: .zero) }
            player.play()
            isPlaying = true
        }
    }

    private func setup() {
        let item = AVPlayerItem(url: url)
        let p = AVPlayer(playerItem: item)
        player = p

        observer = p.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: 600),
            queue: .main
        ) { time in
            let dur = item.duration.seconds
            if dur.isFinite, dur > 0 {
                duration = dur
                progress = min(1, time.seconds / dur)
            }
        }

        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { _ in
            isPlaying = false
            progress = 1
        }
    }

    private func teardown() {
        player?.pause()
        if let observer { player?.removeTimeObserver(observer) }
        observer = nil
        player = nil
        isPlaying = false
    }

    private func timeString(_ t: Double) -> String {
        let total = Int(t.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
