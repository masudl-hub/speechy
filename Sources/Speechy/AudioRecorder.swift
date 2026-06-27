import AVFoundation

/// Captures microphone audio and converts it to the 16 kHz mono Float32 array
/// WhisperKit expects. Emits a live RMS level for the floaty's meter.
final class AudioRecorder {
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                             sampleRate: 16_000,
                                             channels: 1,
                                             interleaved: false)!
    private var samples: [Float] = []
    private let lock = NSLock()

    /// Called ~frequently with a 0...1 RMS level.
    var onLevel: ((Float) -> Void)?

    private(set) var isRecording = false

    func start() throws {
        guard !isRecording else { return }
        lock.withLock { samples.removeAll(keepingCapacity: true) }

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        converter = AVAudioConverter(from: inputFormat, to: targetFormat)

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.process(buffer: buffer)
        }

        engine.prepare()
        try engine.start()
        isRecording = true
    }

    /// Stop capture and return the accumulated 16 kHz mono samples.
    @discardableResult
    func stop() -> [Float] {
        guard isRecording else { return [] }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRecording = false
        return lock.withLock { samples }
    }

    private func process(buffer: AVAudioPCMBuffer) {
        guard let converter else { return }

        // Resample/convert into 16 kHz mono Float32.
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        var consumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        if error != nil { return }

        guard let channel = out.floatChannelData?[0] else { return }
        let frames = Int(out.frameLength)
        guard frames > 0 else { return }

        var chunk = [Float](repeating: 0, count: frames)
        for i in 0..<frames { chunk[i] = channel[i] }

        lock.withLock { samples.append(contentsOf: chunk) }

        // RMS for the meter.
        var sum: Float = 0
        for v in chunk { sum += v * v }
        let rms = (frames > 0) ? sqrtf(sum / Float(frames)) : 0
        let level = min(1, rms * 6)  // scale up; speech RMS is small
        onLevel?(level)
    }
}
