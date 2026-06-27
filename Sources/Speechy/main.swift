import AppKit

// Menu-bar-only app (no Dock icon). LSUIElement in Info.plist reinforces this
// for the bundled .app; .accessory covers the case of running the bare binary.
// Top-level code already runs on the main thread; assert that for the actor.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
