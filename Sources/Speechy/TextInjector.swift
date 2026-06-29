import AppKit
import CoreGraphics

/// Drops text into the focused app's text field by writing to the pasteboard
/// and synthesizing ⌘V, then restoring the previous pasteboard contents.
/// Works in virtually every native, Electron, and web text field.
enum TextInjector {

    /// Snapshot + set + paste + restore. Leaves `text` recoverable on the
    /// clipboard for a moment even if paste fails (restore is delayed).
    static func paste(_ text: String) {
        guard !text.isEmpty else { return }
        let pasteboard = NSPasteboard.general

        // Snapshot existing items so we can restore the user's clipboard.
        let saved = pasteboard.pasteboardItems?.compactMap { item -> [NSPasteboard.PasteboardType: Data] in
            var dict: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { dict[type] = data }
            }
            return dict
        }

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Synthesize Cmd+V.
        postCommandV()

        // Restore previous clipboard after the paste has landed.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            guard let saved else { return }
            pasteboard.clearContents()
            for itemDict in saved {
                let item = NSPasteboardItem()
                for (type, data) in itemDict { item.setData(data, forType: type) }
                pasteboard.writeObjects([item])
            }
        }
    }

    /// Leaves text on the clipboard without restoring — used as a backstop
    /// when we want the user to be able to ⌘V manually.
    static func copyOnly(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private static func postCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let vKey: CGKeyCode = 0x09  // 'v'

        let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true)
        down?.flags = .maskCommand
        let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        up?.flags = .maskCommand

        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    static func frontmostAppName() -> String {
        NSWorkspace.shared.frontmostApplication?.localizedName ?? "Unknown"
    }
}
