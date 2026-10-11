import AVFoundation
import Speech
import Combine

enum YouraVoiceAccess {
    static func canRecord(onDevice: Bool, speechAuthorized: Bool, microphoneAllowed: Bool, available: Bool) -> Bool {
        onDevice && speechAuthorized && microphoneAllowed && available
    }
}
@MainActor final class YouraSpeech: ObservableObject {
    @Published var transcript = ""
    @Published var recording = false
    @Published var preparing = false
    @Published var status = ""
    private let engine = AVAudioEngine()
    private let synthesizer = AVSpeechSynthesizer()
    private var task: SFSpeechRecognitionTask?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var tapped = false
    private var revision = 0
    private var deadline: Task<Void, Never>?
    func start() async {
        guard !recording, !preparing else { return }
        revision += 1; let generation = revision
        preparing = true; status = "Checking on-device voice access…"
        defer { if generation == revision { preparing = false } }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en_US")), recognizer.supportsOnDeviceRecognition else {
            status = "English on-device transcription is unavailable. Type your check-in; no audio was uploaded."; return
        }
        let speech = await withCheckedContinuation { continuation in SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) } }
        guard generation == revision else { return }
        guard speech == .authorized else { status = "Speech access is unavailable. You can type, or review permissions in iPhone Settings."; return }
        let mic = await withCheckedContinuation { continuation in AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) } }
        guard generation == revision else { return }
        guard YouraVoiceAccess.canRecord(onDevice: recognizer.supportsOnDeviceRecognition, speechAuthorized: speech == .authorized,
            microphoneAllowed: mic, available: recognizer.isAvailable) else { status = "Microphone or local recognition is unavailable. Type your check-in instead."; return }
        do {
            synthesizer.stopSpeaking(at: .immediate)
            let audio = AVAudioSession.sharedInstance()
            try audio.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .duckOthers])
            try audio.setActive(true)
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.requiresOnDeviceRecognition = true; request.shouldReportPartialResults = true
            self.request = request; transcript = ""
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else { throw NSError(domain: "YouraSpeech", code: 1) }
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in request.append(buffer) }
            tapped = true; engine.prepare(); try engine.start(); recording = true; status = "Listening locally. Tap Finish when you’re done."
            task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                Task { @MainActor in
                    guard let self, generation == self.revision else { return }
                    if let result { self.transcript = result.bestTranscription.formattedString }
                    if result?.isFinal == true || error != nil {
                        self.stop(); self.status = error == nil ? "Review your transcript before using it." : "Recognition stopped. Review the text or type your check-in."
                    }
                }
            }
            deadline = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(50)) } catch { return }
                guard let self, generation == self.revision else { return }
                self.stop(); self.status = "Turn finished. Review the transcript or record another short turn."
            }
        } catch { stop(); status = "Voice recording couldn’t start. Type your check-in instead." }
    }
    func stop() {
        revision += 1; preparing = false; recording = false
        deadline?.cancel(); deadline = nil
        engine.stop()
        if tapped { engine.inputNode.removeTap(onBus: 0); tapped = false }
        request?.endAudio(); task?.cancel(); task = nil; request = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
    func speak(_ text: String) {
        guard !recording, !preparing else { return }
        synthesizer.stopSpeaking(at: .immediate)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        let utterance = AVSpeechUtterance(string: text); utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        synthesizer.speak(utterance)
    }
    func silence() { synthesizer.stopSpeaking(at: .immediate); try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
}
