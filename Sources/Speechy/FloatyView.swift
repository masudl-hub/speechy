import SwiftUI

/// The floaty — an iridescent fluid "pool" that morphs between states:
/// a tiny calm pill at rest, an audio-reactive pool while listening, a
/// coalescing shimmer while processing. Click = start/stop; drag = reposition.
struct FloatyView: View {
    @ObservedObject var state: AppState
    var onMove: (CGSize) -> Void
    var onMoveEnded: () -> Void

    @State private var lastTranslation: CGSize = .zero

    var body: some View {
        ZStack {
            Capsule(style: .continuous)
                .fill(.black.opacity(0.25))
                .overlay(fluid.clipShape(Capsule(style: .continuous)))
                .overlay(grain.clipShape(Capsule(style: .continuous)))
                .overlay(content)
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(.white.opacity(0.18), lineWidth: 0.5)
                )
                .frame(width: pillSize.width, height: pillSize.height)
                .shadow(color: glow.opacity(0.55), radius: glowRadius, y: 1)
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
                            if moved < 4 { state.onActivate?() } else { onMoveEnded() }
                        }
                )
                .animation(.spring(response: 0.34, dampingFraction: 0.82), value: pillSize)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Fluid fill

    @ViewBuilder private var fluid: some View {
        if #available(macOS 15.0, *) {
            FluidMesh(activity: activity, palette: palette)
        } else {
            // Fallback for macOS 14: a slowly rotating iridescent gradient.
            TimelineView(.animation) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate
                AngularGradient(colors: palette + [palette[0]], center: .center,
                                angle: .degrees(t.truncatingRemainder(dividingBy: 12) / 12 * 360))
                    .blur(radius: 8)
            }
        }
    }

    private var grain: some View {
        Rectangle()
            .fill(.white.opacity(0.03))
            .blendMode(.overlay)
    }

    // MARK: - Per-phase content (only for non-fluid states)

    @ViewBuilder private var content: some View {
        switch state.phase {
        case .loadingModel(let p):
            Text("\(Int(p * 100))%")
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.85))
        case .error(let msg):
            Text(msg)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white).lineLimit(1).padding(.horizontal, 10)
        default:
            EmptyView()
        }
    }

    // MARK: - Phase → shape, motion, color

    private var pillSize: CGSize {
        switch state.phase {
        case .listening, .locked: return CGSize(width: 208, height: 60)
        case .transcribing, .cleaning, .pasting: return CGSize(width: 132, height: 44)
        case .loadingModel: return CGSize(width: 62, height: 24)
        case .error: return CGSize(width: 224, height: 30)
        case .idle: return state.hovering ? CGSize(width: 64, height: 22) : CGSize(width: 48, height: 17)
        }
    }

    /// Fluid agitation, 0…1.
    private var activity: CGFloat {
        switch state.phase {
        case .listening, .locked: return max(0.18, CGFloat(state.audioLevel))
        case .transcribing, .cleaning, .pasting: return 0.5
        case .idle: return state.hovering ? 0.22 : 0.12
        default: return 0.15
        }
    }

    private var palette: [Color] {
        switch state.phase {
        case .transcribing, .cleaning, .pasting: return Self.processing
        default: return Self.listening
        }
    }

    private var glow: Color {
        switch state.phase {
        case .transcribing, .cleaning, .pasting: return Color(red: 0.1, green: 0.7, blue: 0.85)
        default: return Color(red: 0.6, green: 0.36, blue: 0.96)
        }
    }

    private var glowRadius: CGFloat {
        switch state.phase {
        case .listening, .locked: return 18
        case .transcribing, .cleaning, .pasting: return 12
        default: return 5
        }
    }

    // Iridescent palettes (9 colors → 3×3 mesh).
    static let listening: [Color] = [
        Color(red: 0.55, green: 0.36, blue: 0.96), Color(red: 0.72, green: 0.32, blue: 0.85),
        Color(red: 0.55, green: 0.36, blue: 0.96), Color(red: 0.93, green: 0.28, blue: 0.60),
        Color(red: 0.70, green: 0.30, blue: 0.92), Color(red: 0.45, green: 0.42, blue: 0.98),
        Color(red: 0.55, green: 0.36, blue: 0.96), Color(red: 0.90, green: 0.30, blue: 0.62),
        Color(red: 0.40, green: 0.50, blue: 0.96),
    ]
    static let processing: [Color] = [
        Color(red: 0.06, green: 0.71, blue: 0.83), Color(red: 0.30, green: 0.55, blue: 0.95),
        Color(red: 0.06, green: 0.71, blue: 0.83), Color(red: 0.45, green: 0.42, blue: 0.98),
        Color(red: 0.20, green: 0.62, blue: 0.92), Color(red: 0.55, green: 0.36, blue: 0.96),
        Color(red: 0.06, green: 0.71, blue: 0.83), Color(red: 0.40, green: 0.48, blue: 0.96),
        Color(red: 0.10, green: 0.66, blue: 0.88),
    ]
}

/// Audio-reactive iridescent mesh. Corners are pinned; mid-edge and center
/// control points wobble with time + `activity` to make the fluid roll.
@available(macOS 15.0, *)
private struct FluidMesh: View {
    var activity: CGFloat
    var palette: [Color]

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            MeshGradient(width: 3, height: 3, points: points(t), colors: palette)
                .blur(radius: 4)
        }
    }

    private func points(_ time: TimeInterval) -> [SIMD2<Float>] {
        let amp = Float(0.09 + activity * 0.16)
        let t = Float(time)
        func p(_ x: Float, _ y: Float, _ seed: Float) -> SIMD2<Float> {
            let dx = sin(t * 1.3 + seed) * amp
            let dy = cos(t * 1.05 + seed * 1.7) * amp
            return SIMD2(min(1, max(0, x + dx)), min(1, max(0, y + dy)))
        }
        return [
            SIMD2(0, 0), p(0.5, 0, 1), SIMD2(1, 0),
            p(0, 0.5, 2), p(0.5, 0.5, 3), p(1, 0.5, 4),
            SIMD2(0, 1), p(0.5, 1, 5), SIMD2(1, 1),
        ]
    }
}
