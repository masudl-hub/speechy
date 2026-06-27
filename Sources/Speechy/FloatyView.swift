import SwiftUI

/// Minimal floaty: a tiny collapsed pill at rest, a live waveform while
/// listening, a self-oscillating wave while processing, a hover hint.
/// The pill animates its size *inside a fixed window* (so hover never jitters).
/// Click = start/stop; drag = reposition.
struct FloatyView: View {
    @ObservedObject var state: AppState
    var onMove: (CGSize) -> Void
    var onMoveEnded: () -> Void

    @State private var lastTranslation: CGSize = .zero

    var body: some View {
        ZStack {
            Capsule(style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(.white.opacity(0.10), lineWidth: 0.5)
                )
                .overlay(content)
                .frame(width: pillSize.width, height: pillSize.height)
                .shadow(color: .black.opacity(0.22), radius: 6, y: 2)
                .contentShape(Capsule())
                .onHover { state.hovering = $0 }
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let delta = CGSize(
                                width: value.translation.width - lastTranslation.width,
                                height: value.translation.height - lastTranslation.height
                            )
                            onMove(delta)
                            lastTranslation = value.translation
                        }
                        .onEnded { value in
                            lastTranslation = .zero
                            let moved = abs(value.translation.width) + abs(value.translation.height)
                            if moved < 4 { state.onActivate?() }   // it was a click
                            else { onMoveEnded() }                  // it was a drag
                        }
                )
                .animation(.spring(response: 0.3, dampingFraction: 0.85), value: pillSize)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Pill size per phase (animated inside the fixed window)

    private var pillSize: CGSize {
        switch state.phase {
        case .listening, .locked, .transcribing, .cleaning, .pasting:
            return CGSize(width: 124, height: 30)
        case .loadingModel:
            return CGSize(width: 58, height: 20)
        case .error:
            return CGSize(width: 224, height: 30)
        case .idle:
            return state.hovering ? CGSize(width: 264, height: 30) : CGSize(width: 46, height: 15)
        }
    }

    // MARK: - Content per phase

    @ViewBuilder private var content: some View {
        switch state.phase {
        case .listening, .locked:
            Waveform(level: CGFloat(state.audioLevel), live: true).padding(.horizontal, 10)

        case .transcribing, .cleaning, .pasting:
            Waveform(level: 0.6, live: false).padding(.horizontal, 10)   // self-oscillating

        case .loadingModel(let p):
            Text("\(Int(p * 100))%")
                .font(.system(size: 9, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)

        case .error(let msg):
            Text(msg)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.yellow).lineLimit(1).padding(.horizontal, 10)

        case .idle:
            if state.hovering {
                Text("hold \(Settings.shared.hotkeyLabel) · tap \(Settings.shared.holdComboLabel) to lock")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary).lineLimit(1).padding(.horizontal, 12)
            } else {
                HStack(spacing: 2.5) {
                    ForEach(0..<3, id: \.self) { _ in
                        Circle().fill(.secondary.opacity(0.45)).frame(width: 2.5, height: 2.5)
                    }
                }
            }
        }
    }
}

/// Row of bars. `live`: heights follow the mic level. `!live`: self-oscillates
/// (used while processing) via an animation timeline.
private struct Waveform: View {
    var level: CGFloat
    var live: Bool
    private let bars = 11

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: 2.5) {
                ForEach(0..<bars, id: \.self) { i in
                    Capsule()
                        .fill(.primary.opacity(0.85))
                        .frame(width: 2.5, height: barHeight(i, t))
                }
            }
            .frame(maxHeight: .infinity)
        }
    }

    private func barHeight(_ i: Int, _ t: TimeInterval) -> CGFloat {
        let mid = Double(bars - 1) / 2
        let dist = abs(Double(i) - mid) / mid
        let envelope = 1.0 - 0.55 * dist
        if live {
            let wobble = 0.65 + 0.35 * sin(t * 9 + Double(i))
            return 4 + CGFloat(max(0.06, level) * envelope * wobble) * 18
        } else {
            let wave = 0.5 + 0.5 * sin(t * 6 + Double(i) * 0.7)
            return 4 + CGFloat(wave * envelope) * 14
        }
    }
}
