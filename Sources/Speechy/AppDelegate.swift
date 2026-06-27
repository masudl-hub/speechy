import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let state = AppState.shared
    private var panel: FloatingPanel?
    private var statusItem: NSStatusItem?

    private let recorder = AudioRecorder()
    private let transcriber = Transcriber()
    private let hotkeys = HotkeyManager()

    private var targetApp: String = "Unknown"
    private var installedCleanup: Set<String> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        setupPanel()
        setupHotkeys()
        wireAudioLevel()

        requestPermissions()
        loadModel()
        refreshInstalledCleanupModels()
    }

    private func refreshInstalledCleanupModels() {
        Task {
            let installed = await Ollama.installedModels()
            installedCleanup = installed
            statusItem?.menu = buildMenu()
        }
    }

    // MARK: - UI

    private func setupPanel() {
        let panel = FloatingPanel(state: state)
        panel.show()
        self.panel = panel
    }

    private func setupStatusItem() {
        let item = NSStatusItem.makeMenuBarItem()
        item.button?.title = "🎙"
        item.menu = buildMenu()
        statusItem = item
    }

    private func wireAudioLevel() {
        recorder.onLevel = { [weak self] level in
            Task { @MainActor in self?.state.audioLevel = level }
        }
    }

    private func setupHotkeys() {
        hotkeys.onStartHold = { [weak self] in self?.startRecording(locked: false) }
        hotkeys.onStopHold = { [weak self] in self?.stopAndProcess() }
        hotkeys.onCancelHold = { [weak self] in self?.cancelRecording() }
        hotkeys.onToggleLock = { [weak self] on in
            if on { self?.startRecording(locked: true) }
            else { self?.stopAndProcess() }
        }
        // Clicking the floaty toggles hands-free recording.
        state.onActivate = { [weak self] in
            guard let self else { return }
            if self.recorder.isRecording { self.stopAndProcess() }
            else { self.startRecording(locked: true) }
        }
    }

    // MARK: - Permissions & model

    private var hotkeyRetryTimer: Timer?
    private var openedSettingsOnce = false

    private func requestPermissions() {
        PermissionsManager.requestMicrophone { [weak self] granted in
            self?.state.micGranted = granted
            if !granted { PermissionsManager.openMicrophoneSettings() }
        }
        state.accessibilityGranted = PermissionsManager.accessibilityGranted(prompt: true)
        startHotkeyWithRetry()
    }

    /// Attach the keyboard listener; if the grant isn't in place yet, keep
    /// retrying every few seconds so the hotkey "just starts working" the moment
    /// the user flips the toggle — no relaunch required.
    private func startHotkeyWithRetry() {
        if hotkeys.start() {
            state.accessibilityGranted = true
            if case .error = state.phase { state.phase = .idle }
            return
        }

        state.phase = .error("Enable Accessibility for Speechy")
        if !openedSettingsOnce {
            openedSettingsOnce = true
            PermissionsManager.openAccessibilitySettings()
            PermissionsManager.openInputMonitoringSettings()
        }

        guard hotkeyRetryTimer == nil else { return }
        hotkeyRetryTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            if self.hotkeys.start() {
                timer.invalidate()
                self.hotkeyRetryTimer = nil
                self.state.accessibilityGranted = true
                if case .error = self.state.phase { self.state.phase = .idle }
            }
        }
    }

    private func loadModel() {
        let model = Settings.shared.model
        state.phase = .loadingModel(progress: 0)
        Task {
            do {
                try await transcriber.load(model: model) { progress in
                    Task { @MainActor in self.state.phase = .loadingModel(progress: progress) }
                }
                state.modelReady = true
                state.phase = .idle
            } catch {
                state.phase = .error("Model load failed")
            }
        }
    }

    // MARK: - Dictation pipeline

    private func startRecording(locked: Bool) {
        guard state.modelReady else {
            state.phase = .error("Model still loading…")
            return
        }
        guard PermissionsManager.microphoneGranted() else {
            PermissionsManager.openMicrophoneSettings()
            return
        }
        targetApp = TextInjector.frontmostAppName()
        do {
            try recorder.start()
            state.phase = locked ? .locked : .listening
            // Preload the cleanup model now so its cold-load overlaps speaking +
            // transcription, and it's warm by the time we paste.
            if Settings.shared.postProcessingEnabled && Settings.shared.cleanupEnabled {
                Task { await Cleanup.warmup() }
            }
        } catch {
            state.phase = .error("Mic unavailable")
        }
    }

    /// Abort an in-flight recording without transcribing (e.g. a hold that
    /// turned into an Fn+Space combo).
    private func cancelRecording() {
        guard recorder.isRecording else { return }
        _ = recorder.stop()
        state.audioLevel = 0
        state.phase = .idle
    }

    private func stopAndProcess() {
        guard recorder.isRecording else { return }
        let samples = recorder.stop()
        state.audioLevel = 0
        state.phase = .transcribing

        Task {
            do {
                let raw = try await transcriber.transcribe(samples: samples)
                guard !raw.isEmpty else { state.phase = .idle; return }

                let pp = Settings.shared.postProcessingEnabled
                let doStructure = pp && Settings.shared.cleanupEnabled
                let doCasing = pp && Settings.shared.smartInsert
                let preceding = doCasing ? TextContext.precedingText() : nil

                // Layer 1 — deterministic prettify (instant): punctuation, casing,
                // spacing, filler, spoken commands. Never changes the words.
                let prepared = doCasing ? Prettifier.clean(raw) : raw

                let cleaned: String
                if doStructure {
                    // Layer 2 — LLM structure-only (paragraphs/lists), streamed live.
                    state.phase = .cleaning
                    let inserter = StreamInserter(preceding: preceding, casing: doCasing)
                    cleaned = await Cleanup.processStreaming(prepared) { piece in
                        await MainActor.run { inserter.feed(piece) }
                    }
                } else {
                    // No structuring: insert the deterministically-prettified text atomically.
                    state.phase = .pasting
                    cleaned = prepared
                    TextInjector.paste(doCasing ? SmartJoin.adjust(prepared, preceding: preceding) : prepared)
                }

                HistoryStore.shared.append(raw: raw, cleaned: cleaned, app: targetApp)
                state.lastText = cleaned
                refreshHistoryMenu()

                try? await Task.sleep(nanoseconds: 250_000_000)
                state.phase = .idle
            } catch {
                state.phase = .error("Transcription failed")
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                state.phase = .idle
            }
        }
    }

    // MARK: - Menu

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(makeHeader("Speechy — local dictation"))
        menu.addItem(.separator())

        menu.addItem(buildSpeechToTextItem())
        menu.addItem(buildPostProcessingItem())

        menu.addItem(.separator())
        let historyItem = NSMenuItem(title: "History (24h)", action: nil, keyEquivalent: "")
        historyItem.submenu = buildHistoryMenu()
        historyMenuItem = historyItem
        menu.addItem(historyItem)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Speechy", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        return menu
    }

    /// "Speech-to-text ▸" — the Whisper (voice → text) model + its vocabulary prompt.
    private func buildSpeechToTextItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Speech-to-text", action: nil, keyEquivalent: "")
        let sub = NSMenu()

        let modelItem = NSMenuItem(title: "Model", action: nil, keyEquivalent: "")
        let modelMenu = NSMenu()
        for m in Settings.availableModels {
            let mi = NSMenuItem(title: m.label, action: #selector(selectModel(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = m.id
            mi.state = (m.id == Settings.shared.model) ? .on : .off
            modelMenu.addItem(mi)
        }
        modelItem.submenu = modelMenu
        sub.addItem(modelItem)

        let vocab = NSMenuItem(title: "Custom vocabulary…", action: #selector(editVocabulary), keyEquivalent: "")
        vocab.target = self
        sub.addItem(vocab)

        item.submenu = sub
        return item
    }

    /// "Post-processing ▸" — master toggle, then structuring + casing, then the model.
    private func buildPostProcessingItem() -> NSMenuItem {
        let pp = Settings.shared.postProcessingEnabled
        let item = NSMenuItem(title: "Post-processing", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        sub.autoenablesItems = false   // so we can gray out the sub-options when master is off

        let enabled = NSMenuItem(title: "Enabled", action: #selector(togglePostProcessing), keyEquivalent: "")
        enabled.target = self
        enabled.state = pp ? .on : .off
        sub.addItem(enabled)
        sub.addItem(.separator())

        let structuring = NSMenuItem(title: "Structuring (lists & paragraphs)",
                                     action: #selector(toggleCleanup), keyEquivalent: "")
        structuring.target = self
        structuring.state = Settings.shared.cleanupEnabled ? .on : .off
        structuring.isEnabled = pp
        sub.addItem(structuring)

        let casing = NSMenuItem(title: "Casing & spacing (context-aware)",
                                action: #selector(toggleSmartInsert), keyEquivalent: "")
        casing.target = self
        casing.state = Settings.shared.smartInsert ? .on : .off
        casing.isEnabled = pp
        sub.addItem(casing)

        sub.addItem(.separator())

        let modelItem = NSMenuItem(title: "Model", action: nil, keyEquivalent: "")
        modelItem.isEnabled = pp
        let modelMenu = NSMenu()
        for m in Settings.cleanupModels {
            let installed = installedCleanup.contains(m.id)            // live from Ollama, not hard-coded
            let title = installed ? m.label : "\(m.label) — download"
            let mi = NSMenuItem(title: title, action: #selector(selectCleanupModel(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = m.id
            mi.state = (m.id == Settings.shared.cleanupModel) ? .on : .off
            modelMenu.addItem(mi)
        }
        modelItem.submenu = modelMenu
        sub.addItem(modelItem)

        item.submenu = sub
        return item
    }

    private weak var historyMenuItem: NSMenuItem?

    private func buildHistoryMenu() -> NSMenu {
        let menu = NSMenu()
        let entries = HistoryStore.shared.recent(limit: 20)
        if entries.isEmpty {
            menu.addItem(makeHeader("No transcripts yet"))
            return menu
        }
        for entry in entries {
            let preview = String(entry.display.prefix(50))
            let mi = NSMenuItem(title: preview, action: #selector(recopy(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = entry.display
            mi.toolTip = entry.display
            menu.addItem(mi)
        }
        return menu
    }

    private func refreshHistoryMenu() {
        historyMenuItem?.submenu = buildHistoryMenu()
    }

    private func makeHeader(_ text: String) -> NSMenuItem {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    // MARK: - Menu actions

    @objc private func togglePostProcessing() {
        Settings.shared.postProcessingEnabled.toggle()
        statusItem?.menu = buildMenu()
    }

    @objc private func toggleCleanup() {
        Settings.shared.cleanupEnabled.toggle()
        statusItem?.menu = buildMenu()
    }

    @objc private func toggleSmartInsert() {
        Settings.shared.smartInsert.toggle()
        statusItem?.menu = buildMenu()
    }

    @objc private func selectCleanupModel(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        Settings.shared.cleanupModel = id
        statusItem?.menu = buildMenu()
        // If it isn't downloaded yet, pull it in the background, then refresh.
        if !installedCleanup.contains(id) {
            Task {
                await Ollama.pull(id)
                refreshInstalledCleanupModels()
            }
        }
    }

    @objc private func selectModel(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, id != Settings.shared.model else { return }
        Settings.shared.model = id
        statusItem?.menu = buildMenu()
        loadModel()
    }

    @objc private func editVocabulary() {
        let alert = NSAlert()
        alert.messageText = "Custom vocabulary / prompt"
        alert.informativeText = "Names, jargon, product terms — biases Whisper toward these. One line is fine."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 80))
        field.stringValue = Settings.shared.customPrompt
        field.placeholderString = "e.g. Speechy, WhisperKit, Argmax, Kubernetes, Masud"
        alert.accessoryView = field
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            Settings.shared.customPrompt = field.stringValue
        }
    }

    @objc private func recopy(_ sender: NSMenuItem) {
        if let text = sender.representedObject as? String {
            TextInjector.copyOnly(text)
        }
    }

    @objc private func quit() {
        hotkeys.stop()
        NSApp.terminate(nil)
    }
}

extension NSStatusItem {
    static func makeMenuBarItem() -> NSStatusItem {
        NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    }
}
