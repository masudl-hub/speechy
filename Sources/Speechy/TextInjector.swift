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

    /// Inserts text at the cursor by synthesizing Unicode key events — no
    /// clipboard involved. Used for streaming insertion so text appears live as
    /// the cleanup model generates it.
    static func type(_ text: String) {
        guard !text.isEmpty else { return }
        let source = CGEventSource(stateID: .combinedSessionState)
        let units = Array(text.utf16)
        var i = 0
        let stride = 16   // keyboardSetUnicodeString is reliable in small batches
        while i < units.count {
            var batch = Array(units[i..<min(i + stride, units.count)])
            if let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true) {
                down.keyboardSetUnicodeString(stringLength: batch.count, unicodeString: &batch)
                down.post(tap: .cghidEventTap)
            }
            i += stride
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
        let vKey: CGKeyCode = 0x09 // 'v'

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
