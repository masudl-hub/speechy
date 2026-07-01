import CoreGraphics
import SwiftUI

/// The floaty — an iridescent fluid "pool" that morphs between states: a small,
/// dull, grainy pill at rest; an audio-reactive violet/fuchsia pool while
/// listening; a coalescing cyan/violet shimmer while processing. Always gently
/// morphing. Click = start/stop; drag = reposition.
struct FloatyView: View {
    @ObservedObject var state: AppState
    var onMove: (CGSize) -> Void
    var onMoveEnded: () -> Void

    @State private var lastTranslation: CGSize = .zero

    var body: some View {
        ZStack {
            Capsule(style: .continuous)
                .fill(.black.opacity(0.35))
                .overlay(fluid.clipShape(Capsule(style: .continuous)))
                .overlay(GrainOverlay(opacity: grainOpacity).clipShape(Capsule(style: .continuous)))
                .overlay(content)
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(.white.opacity(0.14), lineWidth: 0.5)
                )
                .frame(width: pillSize.width, height: pillSize.height)
                .shadow(color: glow.opacity(glowOpacity), radius: glowRadius, y: 1)
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
            FluidMesh(activity: activity, colors: FloatyView.mesh(paletteBase, 16))
                .saturation(saturation)
                .brightness(brightnessShift)
        } else {
            TimelineView(.animation) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate
                AngularGradient(
                    colors: paletteBase + [paletteBase[0]], center: .center,
                    angle: .degrees(t.truncatingRemainder(dividingBy: 14) / 14 * 360)
                )
                .blur(radius: 8).saturation(saturation).brightness(brightnessShift)
            }
        }
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
        case .listening, .locked: return CGSize(width: 116, height: 36)
        case .transcribing, .cleaning, .pasting: return CGSize(width: 96, height: 32)
        case .loadingModel: return CGSize(width: 60, height: 22)
        case .error: return CGSize(width: 220, height: 30)
        case .idle: return state.hovering ? CGSize(width: 58, height: 20) : CGSize(width: 46, height: 16)
        }
    }

    /// Fluid agitation, 0…1. Time-based motion always runs; audio adds intensity.
    private var activity: CGFloat {
        switch state.phase {
        case .listening, .locked: return 0.35 + CGFloat(state.audioLevel) * 0.65
        case .transcribing, .cleaning, .pasting: return 0.55
        case .idle: return 0.16  // still morphs, just gently
        default: return 0.2
        }
    }

    private var isResting: Bool {
        if case .idle = state.phase { return true }
        return false
    }

    private var paletteBase: [Color] {
        switch state.phase {
        case .transcribing, .cleaning, .pasting: return Self.processingBase
        default: return Self.listeningBase
        }
    }

    // Duller at rest: desaturate + darken; vivid when active.
    private var saturation: Double { isResting ? 0.45 : 1.0 }
    private var brightnessShift: Double { isResting ? -0.22 : 0.0 }
    private var grainOpacity: Double { isResting ? 0.30 : 0.20 }

    private var glow: Color {
        switch state.phase {
        case .transcribing, .cleaning, .pasting: return Color(red: 0.1, green: 0.7, blue: 0.85)
        default: return Color(red: 0.6, green: 0.36, blue: 0.96)
        }
    }
    private var glowOpacity: Double { isResting ? 0.14 : 0.5 }
    private var glowRadius: CGFloat {
        switch state.phase {
        case .listening, .locked: return 14
        case .transcribing, .cleaning, .pasting: return 11
        default: return 3
        }
    }

    // MARK: - Palettes

    static let listeningBase: [Color] = [
        Color(red: 0.55, green: 0.36, blue: 0.96), Color(red: 0.90, green: 0.30, blue: 0.62),
        Color(red: 0.45, green: 0.42, blue: 0.98), Color(red: 0.72, green: 0.30, blue: 0.88),
        Color(red: 0.40, green: 0.50, blue: 0.96),
    ]
    static let processingBase: [Color] = [
        Color(red: 0.06, green: 0.71, blue: 0.83), Color(red: 0.30, green: 0.55, blue: 0.95),
        Color(red: 0.45, green: 0.42, blue: 0.98), Color(red: 0.10, green: 0.66, blue: 0.88),
        Color(red: 0.20, green: 0.62, blue: 0.92),
    ]

    static func mesh(_ base: [Color], _ count: Int) -> [Color] {
        (0..<count).map { base[$0 % base.count] }
    }
}

/// Audio-reactive 4×4 iridescent mesh. Corners pinned; every other control point
/// rolls with two layered sine waves (organic, always-in-motion) whose amplitude
/// scales with `activity`.
@available(macOS 15.0, *)
private struct FluidMesh: View {
    var activity: CGFloat
    var colors: [Color]

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            MeshGradient(width: 4, height: 4, points: points(t), colors: colors)
                .blur(radius: 7)
        }
    }

    private func points(_ time: TimeInterval) -> [SIMD2<Float>] {
        let amp = Float(0.045 + activity * 0.075)
        let t = Float(time)
        let n = 4
        var pts: [SIMD2<Float>] = []
        pts.reserveCapacity(n * n)
        for j in 0..<n {
            for i in 0..<n {
                let x = Float(i) / Float(n - 1)
                let y = Float(j) / Float(n - 1)
                let corner = (i == 0 || i == n - 1) && (j == 0 || j == n - 1)
                if corner {
                    pts.append(SIMD2(x, y))
                    continue
                }
                let s = Float(i * 7 + j * 13)
                let dx = (sin(t * 0.9 + s) + 0.55 * sin(t * 1.7 + s * 2.3)) * amp
                let dy = (cos(t * 0.8 + s * 1.3) + 0.55 * cos(t * 1.5 + s)) * amp
                pts.append(SIMD2(min(1, max(0, x + dx)), min(1, max(0, y + dy))))
            }
        }
        return pts
    }
}

/// Boiling film grain — a tiled random-noise texture whose offset jitters each
/// frame so it feels alive.
private struct GrainOverlay: View {
    var opacity: Double

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            GrainTexture.image
                .resizable(resizingMode: .tile)
                .opacity(opacity)
                .blendMode(.overlay)
                .offset(x: CGFloat(Int(t * 24) % 7), y: CGFloat(Int(t * 19) % 5))
        }
    }
}

private enum GrainTexture {
    static let image: Image = {
        let size = 128
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        for i in 0..<(size * size) {
            let v = UInt8.random(in: 55...205)
            pixels[i * 4] = v
            pixels[i * 4 + 1] = v
            pixels[i * 4 + 2] = v
            pixels[i * 4 + 3] = 255
        }
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(
            data: &pixels, width: size, height: size, bitsPerComponent: 8,
            bytesPerRow: size * 4, space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return Image(decorative: ctx.makeImage()!, scale: 1)
    }()
}
