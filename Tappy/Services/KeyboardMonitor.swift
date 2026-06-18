import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Foundation

enum KeyboardTriggerOrigin {
    case localApp
    case globalBackground
}

struct KeyboardTrigger {
    let category: SoundCategory
    let keyCode: UInt16
    let origin: KeyboardTriggerOrigin
}

final class KeyboardMonitor {
    enum CaptureState: Equatable {
        case stopped
        case ready
        case unavailable
    }

    private let duplicateTriggerSuppressionWindow: TimeInterval = 0.08

    private var localKeyMonitor: Any?
    private var localFlagsMonitor: Any?
    private var localKeyUpMonitor: Any?
    private var appDidBecomeActiveObserver: Any?
    private var appDidResignActiveObserver: Any?
    private var eventTap: CFMachPort?
    private var eventTapSource: CFRunLoopSource?

    private var handler: ((KeyboardTrigger) -> Void)?
    private var pressedKeyCodes = Set<UInt16>()
    private var lastEmittedTrigger: KeyboardTrigger?
    private var lastEmittedAt: TimeInterval = 0
    private var wasSecureEventInputEnabled = false

    private(set) var isMonitoring = false
    private(set) var captureState: CaptureState = .stopped

    var onCaptureStateChange: ((CaptureState) -> Void)?

    func start(handler: @escaping (KeyboardTrigger) -> Void) {
        self.handler = handler

        if isMonitoring {
            if captureState != .ready {
                stopEventTap()
                startEventTap()
            }
            return
        }

        installApplicationActivityObservers()

        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.processKeyDown(event) ? nil : event
        }

        localFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.processFlagsChanged(event)
            return event
        }

        localKeyUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyUp) { [weak self] event in
            self?.processKeyUp(event)
            return event
        }

        startEventTap()

        isMonitoring = true
    }

    func stop() {
        removeMonitor(localKeyMonitor)
        removeMonitor(localFlagsMonitor)
        removeMonitor(localKeyUpMonitor)
        removeApplicationActivityObservers()
        localKeyMonitor = nil
        localFlagsMonitor = nil
        localKeyUpMonitor = nil
        stopEventTap()
        handler = nil
        clearPressedKeys()
        isMonitoring = false
        updateCaptureState(.stopped)
    }

    private func removeMonitor(_ monitor: Any?) {
        guard let monitor else { return }
        NSEvent.removeMonitor(monitor)
    }

    private func installApplicationActivityObservers() {
        appDidBecomeActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.clearPressedKeys()
        }

        appDidResignActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.clearPressedKeys()
        }
    }

    private func removeApplicationActivityObservers() {
        if let observer = appDidBecomeActiveObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = appDidResignActiveObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        appDidBecomeActiveObserver = nil
        appDidResignActiveObserver = nil
        clearPressedKeys()
    }

    private func processKeyDown(_ event: NSEvent) -> Bool {
        if !event.isARepeat {
            handleKeyDown(keyCode: event.keyCode, origin: .localApp)
        }

        return shouldConsumeLocalKeyDown(event)
    }

    private func processKeyUp(_ event: NSEvent) {
        handleKeyUp(keyCode: event.keyCode)
    }

    private func processFlagsChanged(_ event: NSEvent) {
        handleModifierFlagsChanged(keyCode: event.keyCode, modifierFlags: event.modifierFlags, origin: .localApp)
    }

    private func startEventTap() {
        let mask =
            (CGEventMask(1) << CGEventType.keyDown.rawValue) |
            (CGEventMask(1) << CGEventType.keyUp.rawValue) |
            (CGEventMask(1) << CGEventType.flagsChanged.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else {
                return Unmanaged.passUnretained(event)
            }

            let monitor = Unmanaged<KeyboardMonitor>.fromOpaque(userInfo).takeUnretainedValue()

            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                DispatchQueue.main.async {
                    monitor.handleEventTapDisabled(type: type)
                }

                if let tap = monitor.eventTap {
                    CGEvent.tapEnable(tap: tap, enable: true)
                }
                return Unmanaged.passUnretained(event)
            }

            // Extract only key-code level data on the tap thread. Tappy never
            // reads characters or text from the event stream.
            switch type {
            case .keyDown:
                let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
                let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
                guard !isRepeat else { break }
                DispatchQueue.main.async {
                    monitor.handleGlobalKeyDown(keyCode: keyCode)
                }

            case .keyUp:
                let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
                DispatchQueue.main.async {
                    monitor.handleGlobalKeyUp(keyCode: keyCode)
                }

            case .flagsChanged:
                let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
                let rawFlags = event.flags.rawValue
                DispatchQueue.main.async {
                    monitor.handleGlobalFlagsChanged(keyCode: keyCode, rawFlags: rawFlags)
                }

            default:
                break
            }

            return Unmanaged.passUnretained(event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            updateCaptureState(.unavailable)
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        eventTap = tap
        eventTapSource = source

        CFRunLoopAddSource(CFRunLoopGetMain(), source, CFRunLoopMode.commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        guard CGEvent.tapIsEnabled(tap: tap) else {
            stopEventTap()
            updateCaptureState(.unavailable)
            return
        }

        updateCaptureState(.ready)
    }

    private func stopEventTap() {
        if let source = eventTapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, CFRunLoopMode.commonModes)
        }

        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }

        eventTapSource = nil
        eventTap = nil
    }

    private func handleGlobalKeyDown(keyCode: UInt16) {
        handleKeyDown(keyCode: keyCode, origin: .globalBackground)
    }

    private func handleGlobalKeyUp(keyCode: UInt16) {
        handleKeyUp(keyCode: keyCode)
    }

    private func handleGlobalFlagsChanged(keyCode: UInt16, rawFlags: CGEventFlags.RawValue) {
        let flags = NSEvent.ModifierFlags(rawValue: UInt(rawFlags))
        handleModifierFlagsChanged(keyCode: keyCode, modifierFlags: flags, origin: .globalBackground)
    }

    private func handleKeyDown(keyCode: UInt16, origin: KeyboardTriggerOrigin) {
        guard !synchronizeSecureEventInputState() else { return }

        // Normal keyDown events are already de-duped by the autorepeat flag.
        // Do not keep them in pressedKeyCodes: password fields can suppress
        // keyUp events, leaving stale standard keys that silence later typing.
        emit(triggerForKeyCode(keyCode, origin: origin))
    }

    private func handleKeyUp(keyCode: UInt16) {
        pressedKeyCodes.remove(keyCode)
    }

    private func handleModifierFlagsChanged(
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags,
        origin: KeyboardTriggerOrigin
    ) {
        guard !synchronizeSecureEventInputState() else { return }
        guard isModifierKey(keyCode) else { return }

        if isModifierPress(keyCode: keyCode, modifierFlags: modifierFlags) {
            guard pressedKeyCodes.insert(keyCode).inserted else { return }
            emit(KeyboardTrigger(category: .modifier, keyCode: keyCode, origin: origin))
            return
        }

        pressedKeyCodes.remove(keyCode)
    }

    private func clearPressedKeys() {
        pressedKeyCodes.removeAll()
        lastEmittedTrigger = nil
        lastEmittedAt = 0
    }

    private func emit(_ trigger: KeyboardTrigger) {
        let now = ProcessInfo.processInfo.systemUptime

        if let lastEmittedTrigger,
           trigger.keyCode == lastEmittedTrigger.keyCode,
           trigger.category == lastEmittedTrigger.category,
           now - lastEmittedAt < duplicateTriggerSuppressionWindow {
            return
        }

        lastEmittedTrigger = trigger
        lastEmittedAt = now
        handler?(trigger)
    }

    private func handleEventTapDisabled(type: CGEventType) {
        clearPressedKeys()

        if type == .tapDisabledByUserInput {
            wasSecureEventInputEnabled = true
        }
    }

    private func synchronizeSecureEventInputState() -> Bool {
        let isSecureEventInputEnabled = IsSecureEventInputEnabled()

        if isSecureEventInputEnabled || isSecureEventInputEnabled != wasSecureEventInputEnabled {
            clearPressedKeys()
        }

        wasSecureEventInputEnabled = isSecureEventInputEnabled
        return isSecureEventInputEnabled
    }

    private func shouldConsumeLocalKeyDown(_ event: NSEvent) -> Bool {
        // Local monitors only see events being dispatched to Tappy. If no real
        // text editor is focused, consume text-like keyDown events after Tappy
        // plays its sound so AppKit does not also emit the system disabled beep.
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !flags.contains(.command) else { return false }
        guard !focusedResponderAcceptsTextInput() else { return false }

        return isTextLikeLocalKeyDown(event)
    }

    private func focusedResponderAcceptsTextInput() -> Bool {
        guard let firstResponder = NSApp.keyWindow?.firstResponder else {
            return false
        }

        return firstResponder is NSTextView
    }

    private func isTextLikeLocalKeyDown(_ event: NSEvent) -> Bool {
        switch Int(event.keyCode) {
        case kVK_Escape,
             kVK_Tab,
             kVK_Home,
             kVK_End,
             kVK_PageUp,
             kVK_PageDown,
             kVK_LeftArrow,
             kVK_RightArrow,
             kVK_DownArrow,
             kVK_UpArrow:
            return false
        default:
            break
        }

        guard let characters = event.charactersIgnoringModifiers, !characters.isEmpty else {
            return false
        }

        // Function/navigation keys are represented as private-use Unicode
        // scalars. Let those continue through so app/system keyboard handling
        // is not swallowed just to suppress a beep.
        return !characters.unicodeScalars.contains { scalar in
            (0xF700...0xF8FF).contains(Int(scalar.value))
        }
    }

    private func isModifierKey(_ keyCode: UInt16) -> Bool {
        switch keyCode {
        case 54, 55, 56, 57, 58, 59, 60, 61, 62, 63:
            return true
        default:
            return false
        }
    }

    private func isModifierPress(keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags) -> Bool {
        switch keyCode {
        case 54, 55:
            return modifierFlags.contains(.command)
        case 56, 60:
            return modifierFlags.contains(.shift)
        case 58, 61:
            return modifierFlags.contains(.option)
        case 59, 62:
            return modifierFlags.contains(.control)
        case 57:
            return modifierFlags.contains(.capsLock)
        case 63:
            return modifierFlags.contains(.function)
        default:
            return false
        }
    }

    private func triggerForKeyCode(_ keyCode: UInt16, origin: KeyboardTriggerOrigin) -> KeyboardTrigger {
        switch Int(keyCode) {
        case kVK_Space:
            return KeyboardTrigger(category: .space, keyCode: keyCode, origin: origin)
        case kVK_Return, kVK_ANSI_KeypadEnter:
            return KeyboardTrigger(category: .returnKey, keyCode: keyCode, origin: origin)
        case kVK_Delete, kVK_ForwardDelete:
            return KeyboardTrigger(category: .delete, keyCode: keyCode, origin: origin)
        default:
            return KeyboardTrigger(category: .standard, keyCode: keyCode, origin: origin)
        }
    }

    private func updateCaptureState(_ newState: CaptureState) {
        guard captureState != newState else { return }
        captureState = newState

        if Thread.isMainThread {
            onCaptureStateChange?(newState)
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.onCaptureStateChange?(newState)
            }
        }
    }
}
