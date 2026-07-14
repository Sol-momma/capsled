import CoreFoundation
import Foundation
import IOKit.hid
import IOKit.hidsystem

protocol PhysicalCapsLockWatching: AnyObject {
    func prepare() throws
    func activate(onPress: @escaping () -> Void)
    func stopAndWait()
}

enum PhysicalCapsLockWatcherError: LocalizedError {
    case inputMonitoringPermissionRequired
    case keyboardNotFound
    case managerOpenFailed(IOReturn)
    case alreadyRunning

    var errorDescription: String? {
        switch self {
        case .inputMonitoringPermissionRequired:
            "Input Monitoring permission is required; enable capsled in "
                + "System Settings > Privacy & Security > Input Monitoring, "
                + "then run `capsled watch` again"
        case .keyboardNotFound:
            "no raw HID keyboard was found"
        case let .managerOpenFailed(code):
            "could not open raw HID keyboard monitoring "
                + "(IOKit error \(String(format: "0x%08x", UInt32(bitPattern: code))))"
        case .alreadyRunning:
            "physical Caps Lock monitoring is already running"
        }
    }

    var exitStatus: Int32 {
        switch self {
        case .inputMonitoringPermissionRequired: 77 // EX_NOPERM from sysexits(3).
        default: 69 // EX_UNAVAILABLE from sysexits(3).
        }
    }
}

/// Recognizes one press edge per physical device while ignoring release and
/// duplicate down values. Some keyboards repeat or resend an unchanged input
/// value, so checking `value != 0` alone could toggle the LED more than once.
struct CapsLockPressState {
    private var pressedDevices: Set<ObjectIdentifier> = []

    mutating func observe(device: AnyObject, isPressed: Bool) -> Bool {
        let identifier = ObjectIdentifier(device)
        if isPressed {
            return pressedDevices.insert(identifier).inserted
        }

        pressedDevices.remove(identifier)
        return false
    }
}

/// Listens to the keyboard's raw Caps Lock HID usage without seizing the device.
///
/// Modifier remapping happens inside macOS's HID keyboard filter before a
/// `CGEvent` is produced. At that later layer, physical Caps Lock remapped to
/// Control can be indistinguishable from a real Control key. IOHIDManager input
/// values expose the device element's Keyboard-page usage (`0x39`) before that
/// event-system mapping boundary. Opening with options `0` is passive: input
/// still flows unchanged to macOS and apps. Hardware coverage remains
/// experimental and is documented separately.
final class RawHIDPhysicalCapsLockWatcher: PhysicalCapsLockWatching {
    private static let genericDesktopUsagePage = kHIDPage_GenericDesktop
    private static let keyboardUsage = kHIDUsage_GD_Keyboard
    private static let keyboardUsagePage = kHIDPage_KeyboardOrKeypad
    private static let capsLockUsage = kHIDUsage_KeyboardCapsLock

    private let queue = DispatchQueue(label: "capsled.raw-caps-lock-watcher")
    private var manager: IOHIDManager?
    private var cancellation: DispatchSemaphore?
    private var onPress: (() -> Void)?
    private var pressState = CapsLockPressState()

    func prepare() throws {
        guard manager == nil else {
            throw PhysicalCapsLockWatcherError.alreadyRunning
        }

        try requestInputMonitoringAccessIfNeeded()

        let manager = IOHIDManagerCreate(
            kCFAllocatorDefault,
            IOOptionBits(kIOHIDOptionsTypeNone)
        )
        let deviceMatching = [
            kIOHIDDeviceUsagePageKey: Self.genericDesktopUsagePage,
            kIOHIDDeviceUsageKey: Self.keyboardUsage,
        ] as CFDictionary
        let valueMatching = [
            kIOHIDElementUsagePageKey: Self.keyboardUsagePage,
            kIOHIDElementUsageKey: Self.capsLockUsage,
        ] as CFDictionary

        IOHIDManagerSetDeviceMatching(manager, deviceMatching)
        IOHIDManagerSetInputValueMatching(manager, valueMatching)
        IOHIDManagerRegisterInputValueCallback(
            manager,
            rawHIDInputValueCallback,
            Unmanaged.passUnretained(self).toOpaque()
        )

        // Options `0` deliberately excludes kIOHIDOptionsTypeSeizeDevice. This
        // command observes reports but must never suppress the remapped Control
        // event that the rest of the system receives.
        do {
            try ExternalServiceRetry.perform(
                shouldRetry: { error in
                    guard let watcherError = error as? PhysicalCapsLockWatcherError else {
                        return true
                    }
                    if case .inputMonitoringPermissionRequired = watcherError {
                        return false
                    }
                    return true
                }
            ) {
                let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
                guard result != kIOReturnNotPermitted else {
                    throw PhysicalCapsLockWatcherError.inputMonitoringPermissionRequired
                }
                guard result == kIOReturnSuccess else {
                    throw PhysicalCapsLockWatcherError.managerOpenFailed(result)
                }
            }
        } catch {
            _ = IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            throw error
        }

        do {
            _ = try ExternalServiceRetry.perform {
                guard let devices = IOHIDManagerCopyDevices(manager),
                      CFSetGetCount(devices) > 0
                else {
                    throw PhysicalCapsLockWatcherError.keyboardNotFound
                }
                return devices
            }
        } catch {
            _ = IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            throw error
        }

        self.manager = manager
    }

    func activate(onPress: @escaping () -> Void) {
        guard let manager else {
            preconditionFailure("physical Caps Lock monitoring must be prepared before activation")
        }
        precondition(cancellation == nil, "physical Caps Lock monitoring is already active")

        let cancellation = DispatchSemaphore(value: 0)
        self.onPress = onPress
        self.cancellation = cancellation
        IOHIDManagerSetDispatchQueue(manager, queue)
        IOHIDManagerSetCancelHandler(manager) {
            // IOKit invokes this only after every queued input callback has
            // completed, giving stopAndWait the drain barrier required before
            // the application restores automatic LED ownership.
            cancellation.signal()
        }
        IOHIDManagerActivate(manager)
    }

    func stopAndWait() {
        guard let manager else { return }

        if let cancellation {
            IOHIDManagerCancel(manager)
            cancellation.wait()
        }
        _ = IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))

        self.manager = nil
        self.cancellation = nil
        onPress = nil
        pressState = CapsLockPressState()
    }

    fileprivate func receive(_ value: IOHIDValue) {
        dispatchPrecondition(condition: .onQueue(queue))

        let element = IOHIDValueGetElement(value)
        guard IOHIDElementGetUsagePage(element) == Self.keyboardUsagePage,
              IOHIDElementGetUsage(element) == Self.capsLockUsage
        else {
            return
        }

        let device = IOHIDElementGetDevice(element)
        if shouldPreferBuiltInKeyboard(), !Self.isBuiltIn(device) {
            return
        }

        let isPressed = IOHIDValueGetIntegerValue(value) != 0
        guard pressState.observe(device: device, isPressed: isPressed) else { return }

        // The callback intentionally does no HID property I/O. It forwards a
        // small notification to the application's separate serial state owner,
        // keeping raw input delivery fast and preventing callback reentrancy.
        onPress?()
    }

    private func requestInputMonitoringAccessIfNeeded() throws {
        guard IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) != kIOHIDAccessTypeGranted else {
            return
        }

        // The request can show the system consent UI. macOS commonly requires
        // the newly approved executable to be run again, so a false result is a
        // terminal permission explanation rather than a blind retry loop.
        guard IOHIDRequestAccess(kIOHIDRequestTypeListenEvent) else {
            throw PhysicalCapsLockWatcherError.inputMonitoringPermissionRequired
        }
    }

    private func shouldPreferBuiltInKeyboard() -> Bool {
        guard let manager, let devices = IOHIDManagerCopyDevices(manager) else {
            return false
        }

        // Recompute on the rare Caps Lock event instead of caching startup state.
        // IOHIDManager also tracks future devices, so this keeps hot-plug and
        // keyboard re-enumeration aligned with the LED controller's live scan.
        return (devices as NSSet).contains { candidate in
            let device = candidate as! IOHIDDevice
            return Self.isBuiltIn(device)
        }
    }

    private static func isBuiltIn(_ device: IOHIDDevice) -> Bool {
        (IOHIDDeviceGetProperty(device, kIOHIDBuiltInKey as CFString) as? NSNumber)?.boolValue
            == true
    }
}

private let rawHIDInputValueCallback: IOHIDValueCallback = {
    context,
    result,
    _,
    value in
    guard result == kIOReturnSuccess, let context else { return }

    let watcher = Unmanaged<RawHIDPhysicalCapsLockWatcher>
        .fromOpaque(context)
        .takeUnretainedValue()
    watcher.receive(value)
}
