import AppKit
import Carbon

@MainActor
final class HotKey {
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    var onCancel: (() -> Void)?

    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var isPressed = false
    private static let signature: OSType = 0x4A657644 // JevD

    func register() throws {
        guard hotKey == nil else { return }
        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]
        let installed = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, context in
                guard let event, let context else { return OSStatus(eventNotHandledErr) }
                let owner = Unmanaged<HotKey>.fromOpaque(context).takeUnretainedValue()
                // Carbon application events run on the main event loop.
                return MainActor.assumeIsolated { owner.handle(event) }
            },
            eventTypes.count, &eventTypes,
            Unmanaged.passUnretained(self).toOpaque(), &handler
        )
        guard installed == noErr else {
            throw HotKeyError(code: installed, operation: "Install keyboard handler")
        }
        let registered = RegisterEventHotKey(
            UInt32(kVK_Space), UInt32(controlKey),
            EventHotKeyID(signature: Self.signature, id: 1),
            GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &hotKey
        )
        guard registered == noErr else {
            unregister()
            throw HotKeyError(code: registered, operation: "Register Control–Space")
        }

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == UInt16(kVK_Escape), !event.isARepeat {
                MainActor.assumeIsolated { self?.onCancel?() }
            }
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == UInt16(kVK_Escape), !event.isARepeat {
                MainActor.assumeIsolated { self?.onCancel?() }
            }
        }
    }

    func unregister() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        localMonitor = nil
        globalMonitor = nil
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
        if let handler { RemoveEventHandler(handler) }
        handler = nil
        isPressed = false
    }

    private func handle(_ event: EventRef) -> OSStatus {
        var identifier = EventHotKeyID()
        let result = GetEventParameter(
            event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
            nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier
        )
        guard result == noErr, identifier.signature == Self.signature, identifier.id == 1 else {
            return OSStatus(eventNotHandledErr)
        }
        switch GetEventKind(event) {
        case UInt32(kEventHotKeyPressed):
            if !isPressed {
                isPressed = true
                onPress?()
            }
        case UInt32(kEventHotKeyReleased):
            if isPressed {
                isPressed = false
                onRelease?()
            }
        default:
            return OSStatus(eventNotHandledErr)
        }
        return noErr
    }
}

private struct HotKeyError: LocalizedError {
    let code: OSStatus
    let operation: String

    var errorDescription: String? {
        if code == OSStatus(eventHotKeyExistsErr) {
            return "Control–Space is already registered. Change the conflicting shortcut in System Settings → Keyboard → Keyboard Shortcuts, then restart Desktop Voice."
        }
        return "\(operation) failed (macOS error \(code))."
    }
}
