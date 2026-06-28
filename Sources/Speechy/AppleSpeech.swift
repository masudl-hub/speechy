import AVFoundation
import Speech

/// Lightweight speech-to-text using macOS's built-in on-device recognizer.
/// No model download, tiny footprint — a fast alternative to Whisper. Less
/// accurate on jargon/accents, and not tunable, but instant and free of RAM.
actor AppleSpeech {

    enum AppleSpeechError: Error {
        case unauthorized
        case unavailable
        case onDeviceUnsupported
        case noResult
    }

    /// Request Speech Recognition authorization (shows the system prompt once).
    static func requestAuthorization(_ completion: @escaping (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async { completion(status == .authorized) }
        }
    }

    static var isAuthorized: Bool {
        SFSpeechRecognizer.authorizationStatus() == .authorized
    }

    /// Transcribe 16 kHz mono Float samples fully on-device. Stays offline:
    /// requires on-device support and never falls back to Apple's servers.
    func transcribe(samples: [Float]) async throws -> String {
        guard Self.isAuthorized else { throw AppleSpeechError.unauthorized }
        guard samples.count > 8_000 else { return "" }  // < ~0.5s → ignore

        let recognizerLocale = Locale(identifier: "en-US")
        guard let recognizer = SFSpeechRecognizer(locale: recognizerLocale), recognizer.isAvailable else {
            throw AppleSpeechError.unavailable
        }
        guard recognizer.supportsOnDeviceRecognition else {
            throw AppleSpeechError.onDeviceUnsupported
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true  // never hit the network
        request.shouldReportPartialResults = false
        request.addsPunctuation = true

        guard
            let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))
        else { throw AppleSpeechError.unavailable }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            buffer.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
        }
        request.append(buffer)
        request.endAudio()

        return try await withCheckedThrowingContinuation { continuation in
            var resumed = false
            recognizer.recognitionTask(with: request) { result, error in
                if resumed { return }
                if let error {
                    resumed = true
                    continuation.resume(throwing: error)
                } else if let result, result.isFinal {
                    resumed = true
                    let text = result.bestTranscription.formattedString
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.resume(returning: text)
                }
            }
        }
    }
}
