import AppKit
import CoreGraphics

/// Global hotkey detection via an *active* CGEventTap (needs Accessibility).
/// Wispr-style Fn controls:
///   • Hold Fn (alone)   → push-to-talk: record while held, transcribe on release.
///   • Tap Fn + Space    → toggle hands-free "lock" listening on/off.
///   • Tap Fn (alone)    → while locked, stops it. (No-op when idle.)
/// The Space key in the Fn+Space combo is consumed so no spaces leak into text.
final class HotkeyManager {
    var onStartHold: (() -> Void)?
    var onStopHold: (() -> Void)?
    var onCancelHold: (() -> Void)?
    var onToggleLock: ((_ on: Bool) -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    private let holdThreshold: TimeInterval = 0.35  // hold Fn longer than this → push-to-talk

    private var modCode: CGKeyCode { CGKeyCode(Settings.shared.hotkeyKeyCode) }  // 63 = Fn
    private var holdCode: CGKeyCode { CGKeyCode(Settings.shared.holdKeyCode) }  // 49 = Space

    // Gesture state
    private var fnDown = false
    private var comboUsed = false  // Space was pressed during this Fn press
    private var pttActive = false  // push-to-talk recording (from holding Fn)
    private var lockMode = false
    private var holdWork: DispatchWorkItem?

    func start() -> Bool {
        stop()  // idempotent

        let mask =
            (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let manager = Unmanaged<HotkeyManager>.fromOpaque(refcon).takeUnretainedValue()
            return manager.handle(type: type, event: event)
                ? nil
                : Unmanaged.passUnretained(event)
        }

        guard
            let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: CGEventMask(mask),
                callback: callback,
                userInfo: Unmanaged.passUnretained(self).toOpaque()
            )
        else {
            return false  // Accessibility not granted yet
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let src = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes) }
        eventTap = nil
        runLoopSource = nil
        cancelHoldTimer()
        fnDown = false; comboUsed = false; pttActive = false
    }

    // MARK: - Event handling. Returns true to consume the event.

    private func handle(type: CGEventType, event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        }

        let code = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        let fn = event.flags.contains(.maskSecondaryFn)

        if type == .flagsChanged, code == modCode {
            handleFn(pressed: fn)
            return false  // never consume Fn itself
        }

        if code == holdCode {
            switch type {
            case .keyDown where fn || fnDown:
                // Fn + Space → toggle lock.
                comboUsed = true
                cancelHoldTimer()
                if pttActive {  // a hold had just begun — abandon it
                    pttActive = false
                    onCancelHold?()
                }
                toggleLock()
                return true  // swallow the Space
            case .keyUp where comboUsed:
                return true  // swallow the matching key-up too
            default:
                break
            }
        }
        return false
    }

    private func handleFn(pressed: Bool) {
        if pressed, !fnDown {
            fnDown = true
            comboUsed = false
            // Arm push-to-talk: starts only if Fn is held (no Space, not locked).
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.fnDown, !self.comboUsed, !self.lockMode, !self.pttActive else { return }
                self.pttActive = true
                self.onStartHold?()
            }
            holdWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + holdThreshold, execute: work)
            return
        }

        guard !pressed, fnDown else { return }
        fnDown = false
        cancelHoldTimer()

        if pttActive {  // releasing a held Fn → transcribe
            pttActive = false
            onStopHold?()
            return
        }
        if comboUsed {  // combo already handled on Space-down
            comboUsed = false
            return
        }
        // Quick Fn tap, no combo: stop lock if listening, else nothing.
        if lockMode { toggleLock() }
    }

    private func toggleLock() {
        lockMode.toggle()
        onToggleLock?(lockMode)
    }

    private func cancelHoldTimer() {
        holdWork?.cancel()
        holdWork = nil
    }
}
