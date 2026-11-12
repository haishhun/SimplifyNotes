import AVFoundation
import Observation

/// Records and plays audio notes. Recording keeps running while the user writes.
@Observable
final class AudioNoteService: NSObject, AVAudioPlayerDelegate {
    private(set) var isRecording = false
    private(set) var recordingStartedAt: Date?
    private(set) var playingRecordingID: UUID?
    private(set) var playbackProgress: Double = 0

    @ObservationIgnored private var recorder: AVAudioRecorder?
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var currentFile: (name: String, url: URL)?
    @ObservationIgnored private var progressTask: Task<Void, Never>?

    struct FinishedRecording {
        let fileName: String
        let duration: TimeInterval
    }

    func startRecording(store: PageContentStoring) async throws {
        guard !isRecording else { return }
        let granted = await AVAudioApplication.requestRecordPermission()
        guard granted else { throw AppError.microphoneDenied }
        stopPlayback()
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
            try session.setActive(true)
            let file = store.newAudioFileURL()
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
            ]
            let recorder = try AVAudioRecorder(url: file.url, settings: settings)
            guard recorder.record() else { throw AppError.recordingFailed("The recorder couldn't start.") }
            self.recorder = recorder
            currentFile = file
            isRecording = true
            recordingStartedAt = .now
        } catch let error as AppError {
            throw error
        } catch {
            throw AppError.recordingFailed(error.localizedDescription)
        }
    }

    /// Stops and returns the finished file. Safe to call when not recording.
    func stopRecording() -> FinishedRecording? {
        guard let recorder, let file = currentFile else { return nil }
        let duration = recorder.currentTime
        recorder.stop()
        self.recorder = nil
        currentFile = nil
        isRecording = false
        recordingStartedAt = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        return FinishedRecording(fileName: file.name, duration: duration)
    }

    func togglePlayback(of recording: AudioRecording, store: PageContentStoring) throws {
        if playingRecordingID == recording.id {
            stopPlayback()
            return
        }
        stopPlayback()
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
            let player = try AVAudioPlayer(contentsOf: store.audioURL(named: recording.fileName))
            player.delegate = self
            player.play()
            self.player = player
            playingRecordingID = recording.id
            progressTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(200))
                    guard let self, let player = self.player, player.duration > 0 else { return }
                    self.playbackProgress = player.currentTime / player.duration
                }
            }
        } catch {
            throw AppError.recordingFailed(error.localizedDescription)
        }
    }

    func stopPlayback() {
        progressTask?.cancel()
        progressTask = nil
        player?.stop()
        player = nil
        playingRecordingID = nil
        playbackProgress = 0
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.stopPlayback() }
    }
}
