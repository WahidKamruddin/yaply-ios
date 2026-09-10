import AVFoundation
import Foundation

/// Records a single voice message to an AAC `.m4a` file in the temp directory.
/// Used by `VoiceRecorderBar`; the finished file is uploaded to the `media`
/// bucket and sent as a `type: "voice"` message (not E2E encrypted, like all
/// other media).
@Observable
@MainActor
final class AudioRecorderService: NSObject {
    private(set) var isRecording = false
    private(set) var elapsed: TimeInterval = 0
    /// Normalised 0...1 level for a simple meter, updated ~every 0.05s.
    private(set) var level: CGFloat = 0
    private(set) var permissionDenied = false

    private var recorder: AVAudioRecorder?
    private var fileURL: URL?
    private var timer: Timer?

    /// Requests permission (if needed) and starts recording. No-op if already recording.
    func start() async {
        guard !isRecording else { return }

        let granted = await requestPermission()
        guard granted else {
            permissionDenied = true
            return
        }

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            try session.setActive(true)
        } catch {
            return
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
        ]

        do {
            let rec = try AVAudioRecorder(url: url, settings: settings)
            rec.isMeteringEnabled = true
            rec.record()
            recorder = rec
            fileURL = url
            isRecording = true
            elapsed = 0

            let t = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        } catch {
            cleanupSession()
        }
    }

    /// Stops recording and returns the finished file URL (nil on failure / too short).
    func stop() -> URL? {
        guard isRecording else { return nil }
        recorder?.stop()
        timer?.invalidate()
        timer = nil
        isRecording = false
        cleanupSession()
        let url = fileURL
        recorder = nil
        // Guard against accidental sub-second taps.
        if elapsed < 0.8 {
            if let url { try? FileManager.default.removeItem(at: url) }
            return nil
        }
        return url
    }

    /// Stops and discards the recording.
    func cancel() {
        recorder?.stop()
        timer?.invalidate()
        timer = nil
        isRecording = false
        cleanupSession()
        if let url = fileURL { try? FileManager.default.removeItem(at: url) }
        recorder = nil
        fileURL = nil
        elapsed = 0
        level = 0
    }

    private func tick() {
        guard let recorder, recorder.isRecording else { return }
        recorder.updateMeters()
        elapsed = recorder.currentTime
        // -60 dB (quiet) ... 0 dB (loud) → 0...1
        let power = recorder.averagePower(forChannel: 0)
        let normalized = max(0, (power + 60) / 60)
        level = CGFloat(normalized)
    }

    private func requestPermission() async -> Bool {
        await withCheckedContinuation { cont in
            AVAudioApplication.requestRecordPermission { granted in
                cont.resume(returning: granted)
            }
        }
    }

    private func cleanupSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }
}
