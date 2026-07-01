import AppKit
import SwiftUI

/// A fixed-size, borderless, non-activating panel that floats above every app
/// on every Space. It never resizes or re-centers itself — the pill animates
/// *inside* it — so hover never jitters. Draggable; position persists.
final class FloatingPanel: NSPanel {
    private static let canvas = NSSize(width: 300, height: 120)

    init(state: AppState) {
        super.init(
            contentRect: NSRect(origin: .zero, size: Self.canvas),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isMovableByWindowBackground = false  // we drag via the pill's gesture instead
        hidesOnDeactivate = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false  // shadow is drawn on the SwiftUI capsule
        titleVisibility = .hidden
        titlebarAppearsTransparent = true

        let root = FloatyView(
            state: state,
            onMove: { [weak self] delta in self?.move(by: delta) },
            onMoveEnded: { [weak self] in self?.savePosition() }
        )
        let host = NSHostingView(rootView: root)
        host.frame = contentView?.bounds ?? .zero
        host.autoresizingMask = [.width, .height]
        contentView?.addSubview(host)

        restorePosition()
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func show() { orderFrontRegardless() }

    // MARK: - Dragging / position

    private func move(by delta: CGSize) {
        var origin = frame.origin
        origin.x += delta.width
        origin.y -= delta.height  // SwiftUI y is top-down; screen y is bottom-up
        setFrameOrigin(origin)
    }

    private func savePosition() {
        Settings.shared.floatyOrigin = frame.origin
    }

    private func restorePosition() {
        if let origin = Settings.shared.floatyOrigin {
            setFrameOrigin(origin)
        } else if let screen = NSScreen.main {
            let v = screen.visibleFrame
            setFrameOrigin(NSPoint(x: v.midX - Self.canvas.width / 2, y: v.minY + 90))
        }
    }
}
