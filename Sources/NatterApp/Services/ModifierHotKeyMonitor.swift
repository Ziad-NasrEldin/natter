import AppKit
import CoreGraphics
import NatterCore

private struct ModifierFlagsEvent: Sendable {
    let keyCode: UInt16
    let flags: CGEventFlags
    let timestamp: TimeInterval
}

private final class HotKeyEventSink: @unchecked Sendable {
    let eventHandler: @Sendable (ModifierFlagsEvent) -> Void
    let keyEventHandler: @MainActor (
        _ keyCode: UInt16,
        _ modifierFlagsRawValue: UInt64,
        _ isKeyDown: Bool,
        _ isRepeat: Bool,
        _ timestamp: TimeInterval
    ) -> Bool
    let disabledHandler: @Sendable () -> Void

    init(
        eventHandler: @escaping @Sendable (ModifierFlagsEvent) -> Void,
        keyEventHandler: @escaping @MainActor (
            _ keyCode: UInt16,
            _ modifierFlagsRawValue: UInt64,
            _ isKeyDown: Bool,
            _ isRepeat: Bool,
            _ timestamp: TimeInterval
        ) -> Bool,
        disabledHandler: @escaping @Sendable () -> Void
    ) {
        self.eventHandler = eventHandler
        self.keyEventHandler = keyEventHandler
        self.disabledHandler = disabledHandler
    }
}

private func modifierEventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let sink = Unmanaged<HotKeyEventSink>.fromOpaque(userInfo).takeUnretainedValue()

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        sink.disabledHandler()
        return Unmanaged.passUnretained(event)
    }

    if type == .keyDown || type == .keyUp, Thread.isMainThread {
        let isKeyDown = type == .keyDown
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let modifierFlagsRawValue = event.flags.rawValue
        let timestamp = Double(event.timestamp) / 1_000_000_000
        let shouldSuppress = MainActor.assumeIsolated {
            sink.keyEventHandler(
                keyCode,
                modifierFlagsRawValue,
                isKeyDown,
                isRepeat,
                timestamp
            )
        }
        return shouldSuppress ? nil : Unmanaged.passUnretained(event)
    }
    guard type == .flagsChanged else { return Unmanaged.passUnretained(event) }

    sink.eventHandler(ModifierFlagsEvent(
        keyCode: UInt16(event.getIntegerValueField(.keyboardEventKeycode)),
        flags: event.flags,
        timestamp: Double(event.timestamp) / 1_000_000_000
    ))
    return Unmanaged.passUnretained(event)
}

@MainActor
final class ModifierHotKeyMonitor {
    private let store: DictationStore
    private let actionHandler: (ModifierHotKeyAction) -> Void
    private let eventObservationHandler: () -> Void
    private var detector = ModifierTapDetector()
    private var edgeTracker = ModifierKeyEdgeTracker()
    private var cancelTapDetector = CancelModifierTapDetector()
    private var recordingSession = HotKeyRecordingSession()
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var eventSinkPointer: UnsafeMutableRawPointer?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var watchdog: Timer?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var applicationObserver: NSObjectProtocol?
    private var pressStartedDuringSession = false
    private var startTriggeredForPress = false
    private var suppressingModeCycleKey = false
    private var hasProvenInputMonitoring = false
    private var wasRecordingHotKey = false
    private var lastHandledEvent: (keyCode: UInt16, active: Bool, timestamp: TimeInterval)?
    private var lastHotKey: DictationShortcut?

    init(
        store: DictationStore,
        eventObservationHandler: @escaping () -> Void = {},
        actionHandler: @escaping (ModifierHotKeyAction) -> Void
    ) {
        self.store = store
        self.eventObservationHandler = eventObservationHandler
        self.actionHandler = actionHandler
    }

    func start() {
        installEventTapIfNeeded(reason: "start")
        installNSEventMonitorsIfNeeded()
        guard watchdog == nil else { return }
        watchdog = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) {
            [weak self] _ in
            Task { @MainActor in self?.keepEventTapAlive(reason: "watchdog") }
        }
        registerSystemObservers()
    }

    func stop() {
        watchdog?.invalidate()
        watchdog = nil
        removeSystemObservers()
        removeNSEventMonitors()
        tearDownEventTap()
        resetDetectors()
    }

    func restart() {
        tearDownEventTap()
        removeNSEventMonitors()
        installEventTapIfNeeded(reason: "permission-change")
        installNSEventMonitorsIfNeeded()
    }

    private func installEventTapIfNeeded(reason: String) {
        guard eventTap == nil else {
            keepEventTapAlive(reason: reason)
            return
        }

        let sink = HotKeyEventSink(
            eventHandler: { [weak self] event in
                DispatchQueue.main.async { self?.handle(event) }
            },
            keyEventHandler: {
                [weak self] keyCode, modifierFlagsRawValue, isKeyDown, isRepeat, timestamp in
                self?.handleKey(
                    keyCode: keyCode,
                    modifierFlagsRawValue: modifierFlagsRawValue,
                    isKeyDown: isKeyDown,
                    isRepeat: isRepeat,
                    timestamp: timestamp
                ) ?? false
            },
            disabledHandler: { [weak self] in
                DispatchQueue.main.async { self?.keepEventTapAlive(reason: "disabled") }
            }
        )
        let pointer = Unmanaged.passRetained(sink).toOpaque()
        let mask = [CGEventType.flagsChanged, .keyDown, .keyUp].reduce(CGEventMask(0)) {
            $0 | (CGEventMask(1) << $1.rawValue)
        }
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: modifierEventTapCallback,
            userInfo: pointer
        ) else {
            Unmanaged<HotKeyEventSink>.fromOpaque(pointer).release()
            NatterLog.hotKey.error(
                "could not create event tap reason=\(reason, privacy: .public)"
            )
            installNSEventMonitorsIfNeeded()
            return
        }

        removeNSEventMonitors()
        eventTap = tap
        eventSinkPointer = pointer
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        NatterLog.hotKey.notice("event tap active reason=\(reason, privacy: .public)")
    }

    private func keepEventTapAlive(reason: String) {
        guard let eventTap else {
            installEventTapIfNeeded(reason: reason)
            return
        }
        guard !CGEvent.tapIsEnabled(tap: eventTap) else { return }
        CGEvent.tapEnable(tap: eventTap, enable: true)
        if !CGEvent.tapIsEnabled(tap: eventTap) {
            tearDownEventTap()
            installEventTapIfNeeded(reason: reason)
        } else {
            NatterLog.hotKey.notice("event tap re-enabled reason=\(reason, privacy: .public)")
        }
    }

    private func tearDownEventTap() {
        if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: false) }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        runLoopSource = nil
        if let eventTap { CFMachPortInvalidate(eventTap) }
        eventTap = nil
        if let eventSinkPointer {
            Unmanaged<HotKeyEventSink>.fromOpaque(eventSinkPointer).release()
        }
        eventSinkPointer = nil
    }

    private func installNSEventMonitorsIfNeeded() {
        // Do not consume the same modifier sequence from two asynchronous sources.
        // Audio pre-roll can briefly occupy the main actor, allowing duplicated
        // event-tap and NSEvent sequences to interleave and falsely stop a session.
        guard eventTap == nil else { return }
        guard globalMonitor == nil, localMonitor == nil else { return }
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown, .keyUp]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) {
            [weak self] event in
            let type = event.type
            let keyCode = event.keyCode
            let flags = NSEvent.ModifierFlags.cgEventFlags(event.modifierFlags)
            let timestamp = event.timestamp
            let isRepeat = event.isARepeat
            DispatchQueue.main.async {
                _ = self?.handleCopiedNSEvent(
                    type: type,
                    keyCode: keyCode,
                    flags: flags,
                    timestamp: timestamp,
                    isRepeat: isRepeat
                )
            }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) {
            [weak self] event in
            let shouldSuppress = self?.handleCopiedNSEvent(
                type: event.type,
                keyCode: event.keyCode,
                flags: NSEvent.ModifierFlags.cgEventFlags(event.modifierFlags),
                timestamp: event.timestamp,
                isRepeat: event.isARepeat
            ) ?? false
            return shouldSuppress ? nil : event
        }
    }

    private func removeNSEventMonitors() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
    }

    @discardableResult
    private func handleCopiedNSEvent(
        type: NSEvent.EventType,
        keyCode: UInt16,
        flags: CGEventFlags,
        timestamp: TimeInterval,
        isRepeat: Bool
    ) -> Bool {
        switch type {
        case .flagsChanged:
            handle(ModifierFlagsEvent(keyCode: keyCode, flags: flags, timestamp: timestamp))
            return store.isRecordingHotKey
        case .keyDown, .keyUp:
            return handleKey(
                keyCode: keyCode,
                modifierFlagsRawValue: flags.rawValue,
                isKeyDown: type == .keyDown,
                isRepeat: isRepeat,
                timestamp: timestamp
            )
        default:
            return false
        }
    }

    private func registerSystemObservers() {
        guard workspaceObservers.isEmpty, applicationObserver == nil else { return }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            workspaceObservers.append(center.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.recreateAfterSystemTransition(name.rawValue) }
            })
        }
        applicationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.keepEventTapAlive(reason: "application-active") }
        }
    }

    private func removeSystemObservers() {
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.forEach(center.removeObserver)
        workspaceObservers = []
        if let applicationObserver { NotificationCenter.default.removeObserver(applicationObserver) }
        applicationObserver = nil
    }

    private func recreateAfterSystemTransition(_ reason: String) {
        resetDetectors()
        tearDownEventTap()
        removeNSEventMonitors()
        installEventTapIfNeeded(reason: reason)
        installNSEventMonitorsIfNeeded()
    }

    private func resetDetectors() {
        edgeTracker.reset()
        detector.reset()
        cancelTapDetector.reset()
        recordingSession.reset()
        pressStartedDuringSession = false
        startTriggeredForPress = false
        suppressingModeCycleKey = false
        lastHandledEvent = nil
    }

    private func handleKey(
        keyCode: UInt16,
        modifierFlagsRawValue: UInt64,
        isKeyDown: Bool,
        isRepeat: Bool,
        timestamp: TimeInterval
    ) -> Bool {
        proveInputMonitoringIfNeeded()
        let modifiers = DictationShortcutModifiers(
            cgEventFlags: CGEventFlags(rawValue: modifierFlagsRawValue)
        )
        if syncHotKeyRecording() {
            let outcome = isKeyDown
                ? recordingSession.observeKeyDown(keyCode: keyCode, modifiers: modifiers)
                : .listening
            applyRecordingOutcome(outcome)
            return true
        }

        let hotKey = storedHotKeyResettingDetectorsIfNeeded()
        if !hotKey.isModifierOnly, hotKey.matches(keyCode: keyCode, modifiers: modifiers) {
            if !isRepeat {
                handleDictationEdge(isActive: isKeyDown, at: timestamp)
            }
            return true
        }

        return handleModeCycleKey(
            keyCode: keyCode,
            modifierFlagsRawValue: modifierFlagsRawValue,
            isKeyDown: isKeyDown,
            isRepeat: isRepeat
        )
    }

    private func handleModeCycleKey(
        keyCode: UInt16,
        modifierFlagsRawValue: UInt64,
        isKeyDown: Bool,
        isRepeat: Bool
    ) -> Bool {
        if !isKeyDown {
            defer { suppressingModeCycleKey = false }
            return suppressingModeCycleKey
        }

        guard store.phase == .listening,
              DictationShortcut.defaultModeCycle.matches(
                keyCode: keyCode,
                modifiers: DictationShortcutModifiers(
                    cgEventFlags: CGEventFlags(rawValue: modifierFlagsRawValue)
                )
              ) else {
            return false
        }
        suppressingModeCycleKey = true
        if !isRepeat { actionHandler(.cycleMode) }
        return true
    }

    private func handle(_ event: ModifierFlagsEvent) {
        proveInputMonitoringIfNeeded()

        let eventModifierIsActive = event.flags.contains(
            DictationShortcut.modifierFlag(for: event.keyCode)
        )
        if syncHotKeyRecording() {
            applyRecordingOutcome(
                recordingSession.observeModifier(
                    keyCode: event.keyCode,
                    isDown: eventModifierIsActive
                )
            )
            return
        }

        if let lastHandledEvent,
           lastHandledEvent.keyCode == event.keyCode,
           lastHandledEvent.active == eventModifierIsActive,
           abs(lastHandledEvent.timestamp - event.timestamp) < 0.01 {
            return
        }
        lastHandledEvent = (event.keyCode, eventModifierIsActive, event.timestamp)

        let hotKey = storedHotKeyResettingDetectorsIfNeeded()
        let sessionIsActive = store.phase == .preparing || store.phase == .listening
        if hotKey.keyCode != CancelModifierTapDetector.leftOptionKeyCode {
            switch cancelTapDetector.observe(
                keyCode: event.keyCode,
                isDown: eventModifierIsActive,
                at: event.timestamp,
                sessionIsActive: sessionIsActive
            ) {
            case .cancel:
                resetDetectors()
                actionHandler(.cancel)
                return
            case .passThrough:
                break
            }
        }

        guard hotKey.isModifierOnly, event.keyCode == hotKey.keyCode else { return }
        handleDictationEdge(
            isActive: event.flags.contains(hotKey.modifierFlag),
            at: event.timestamp
        )
    }

    private func handleDictationEdge(isActive: Bool, at timestamp: TimeInterval) {
        let sessionIsActive = store.phase == .preparing || store.phase == .listening
        if detector.doubleTapInterval != store.modifierDoubleTapSpeed.interval {
            detector = ModifierTapDetector(
                doubleTapInterval: store.modifierDoubleTapSpeed.interval
            )
        }
        let pressed = edgeTracker.observe(isActive: isActive)
        NatterLog.hotKey.debug(
            "hotkey event active=\(isActive) edge=\(pressed) timestamp=\(String(format: "%.3f", timestamp), privacy: .public)"
        )

        if !isActive {
            defer {
                pressStartedDuringSession = false
                startTriggeredForPress = false
            }
            if pressStartedDuringSession && !startTriggeredForPress {
                actionHandler(.stop)
            }
            return
        }
        guard pressed else { return }

        pressStartedDuringSession = sessionIsActive
        startTriggeredForPress = false
        if !sessionIsActive, let action = detector.keyDown(
            at: timestamp,
            sessionIsActive: false
        ) {
            NatterLog.hotKey.debug("hotkey action=\(String(describing: action), privacy: .public)")
            startTriggeredForPress = action == .start
            actionHandler(action)
        }
    }

    private func syncHotKeyRecording() -> Bool {
        let isRecording = store.isRecordingHotKey
        if isRecording && !wasRecordingHotKey {
            recordingSession.reset()
        } else if !isRecording && wasRecordingHotKey {
            recordingSession.reset()
        }
        wasRecordingHotKey = isRecording
        return isRecording
    }

    private func applyRecordingOutcome(_ outcome: HotKeyRecordingOutcome) {
        switch outcome {
        case .listening:
            break
        case let .captured(shortcut):
            store.select(shortcut)
            recordingSession.reset()
            wasRecordingHotKey = false
            resetDetectors()
        case .cancelled:
            store.cancelHotKeyRecording()
            recordingSession.reset()
            wasRecordingHotKey = false
        case .rejected:
            store.rejectHotKeyRecording(HotKeyRecordingSession.conflictMessage)
        }
    }

    private func storedHotKeyResettingDetectorsIfNeeded() -> DictationShortcut {
        let hotKey = store.selectedHotKey
        if lastHotKey != hotKey {
            lastHotKey = hotKey
            resetDetectors()
        }
        return hotKey
    }

    private func proveInputMonitoringIfNeeded() {
        guard !hasProvenInputMonitoring else { return }
        hasProvenInputMonitoring = true
        eventObservationHandler()
        NatterLog.hotKey.notice("input monitoring proven by delivered event")
    }
}

private extension DictationShortcutModifiers {
    init(cgEventFlags flags: CGEventFlags) {
        var modifiers: DictationShortcutModifiers = []
        if flags.contains(.maskCommand) { modifiers.insert(.command) }
        if flags.contains(.maskShift) { modifiers.insert(.shift) }
        if flags.contains(.maskAlternate) { modifiers.insert(.option) }
        if flags.contains(.maskControl) { modifiers.insert(.control) }
        if flags.contains(.maskSecondaryFn) { modifiers.insert(.function) }
        self = modifiers
    }
}

private extension DictationShortcut {
    var modifierFlag: CGEventFlags {
        Self.modifierFlag(for: keyCode)
    }

    static func modifierFlag(for keyCode: UInt16) -> CGEventFlags {
        switch keyCode {
        case DictationKeyCode.leftOption, DictationKeyCode.rightOption: .maskAlternate
        case DictationKeyCode.leftControl, DictationKeyCode.rightControl: .maskControl
        case DictationKeyCode.leftCommand, DictationKeyCode.rightCommand: .maskCommand
        case DictationKeyCode.leftShift, DictationKeyCode.rightShift: .maskShift
        case DictationKeyCode.capsLock: .maskAlphaShift
        case DictationKeyCode.function: .maskSecondaryFn
        default: []
        }
    }
}

private extension NSEvent.ModifierFlags {
    static func cgEventFlags(_ flags: NSEvent.ModifierFlags) -> CGEventFlags {
        var result: CGEventFlags = []
        if flags.contains(.option) { result.insert(.maskAlternate) }
        if flags.contains(.control) { result.insert(.maskControl) }
        if flags.contains(.command) { result.insert(.maskCommand) }
        if flags.contains(.shift) { result.insert(.maskShift) }
        if flags.contains(.function) { result.insert(.maskSecondaryFn) }
        if flags.contains(.capsLock) { result.insert(.maskAlphaShift) }
        return result
    }
}
