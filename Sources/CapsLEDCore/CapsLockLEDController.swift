import CoreFoundation
import Foundation
import IOKit.hidsystem

// The public SDK exposes only `IOHIDEventSystemClientCreateSimpleClient` in its
// Swift module, although the IOKit binary also exports CreateWithType. Apple's
// IOHIDFamily source documents that Simple clients have a restricted property
// allow-list, while Passive clients are entitlement-free and intended for
// querying and setting service properties. Declaring the exported symbol here
// keeps this unsupported dependency beside the other HID SPI instead of
// spreading it through the application layer.
@_silgen_name("IOHIDEventSystemClientCreateWithType")
private func createEventSystemClient(
    _ allocator: CFAllocator?,
    _ clientType: UInt32,
    _ attributes: CFDictionary?
) -> IOHIDEventSystemClient

public struct LEDUpdateResult: Equatable {
    public let matchedKeyboards: Int
    public let targetedKeyboards: Int
    public let successfulWrites: Int
}

public protocol CapsLockLEDControlling: AnyObject {
    func setMode(_ mode: LEDMode) throws -> LEDUpdateResult
    func isLEDOn() throws -> Bool
}

public enum CapsLockLEDControlError: LocalizedError {
    case servicesUnavailable
    case keyboardNotFound
    case writeRejected(targetCount: Int)

    public var errorDescription: String? {
        switch self {
        case .servicesUnavailable:
            "macOS did not expose HID event-system services"
        case .keyboardNotFound:
            "no keyboard service was found"
        case let .writeRejected(targetCount):
            "macOS rejected the LED override for \(targetCount) keyboard service(s)"
        }
    }
}

/// Controls the LED override owned by macOS's keyboard event-system filter.
///
/// This deliberately does not open the keyboard device and does not change the
/// logical Caps Lock modifier. The property is present in Apple's open-source
/// IOHIDFamily implementation, but its key and values are not declared in the
/// public SDK headers. Keeping the strings and the write path in this one type
/// makes the unsupported dependency easy to remove if a public API appears.
public final class EventSystemCapsLockLEDController: CapsLockLEDControlling {
    private static let capsLockLEDKey = "HIDCapsLockLED" as CFString
    private static let builtInKey = "Built-In" as CFString

    // IOHIDEventSystemClientType is private in the macOS SDK. Value 2 is the
    // Passive case in Apple's open-source enum. Using Admin or Monitor would
    // require Apple-private entitlements and would also grant event access that
    // this LED-only tool deliberately does not need.
    private static let passiveClientType: UInt32 = 2

    // USB HID Usage Tables: Generic Desktop page 0x01, Keyboard usage 0x06.
    // These values select keyboard services; they are not key codes and no
    // keyboard input reports are registered or read by this process.
    private static let genericDesktopUsagePage: UInt32 = 0x01
    private static let keyboardUsage: UInt32 = 0x06

    // The LED property is one shared, last-writer-wins value. Retaining this
    // client does not reserve that value: HIServices can still overwrite it
    // while handling modifier changes. One client is kept only to avoid
    // repeatedly creating event-system connections while `run` polls the
    // physical state and repairs a foreign Off write.
    private let client: IOHIDEventSystemClient

    public init() {
        client = createEventSystemClient(
            kCFAllocatorDefault,
            Self.passiveClientType,
            nil
        )
    }

    public func setMode(_ mode: LEDMode) throws -> LEDUpdateResult {
        let selection = try targetKeyboards()
        let value = mode.eventSystemValue as NSString
        let successfulWrites = selection.targets.reduce(into: 0) { count, service in
            if IOHIDServiceClientSetProperty(service, Self.capsLockLEDKey, value) {
                count += 1
            }
        }

        guard successfulWrites > 0 else {
            throw CapsLockLEDControlError.writeRejected(targetCount: selection.targets.count)
        }

        return LEDUpdateResult(
            matchedKeyboards: selection.all.count,
            targetedKeyboards: selection.targets.count,
            successfulWrites: successfulWrites
        )
    }

    public func isLEDOn() throws -> Bool {
        let selection = try targetKeyboards()

        // Apple's keyboard filter returns the effective physical LED state for
        // this key, not merely the last requested override. Rewriting only when
        // a target reports Off avoids issuing HID writes every poll interval.
        return selection.targets.allSatisfy { service in
            guard let property = IOHIDServiceClientCopyProperty(
                service,
                Self.capsLockLEDKey
            ) else {
                return false
            }
            return (property as? String) == LEDMode.on.eventSystemValue
        }
    }

    private func targetKeyboards() throws -> (
        all: [IOHIDServiceClient],
        targets: [IOHIDServiceClient]
    ) {
        guard let serviceArray = IOHIDEventSystemClientCopyServices(client) else {
            throw CapsLockLEDControlError.servicesUnavailable
        }

        let keyboards = keyboardServices(in: serviceArray)
        guard !keyboards.isEmpty else {
            throw CapsLockLEDControlError.keyboardNotFound
        }

        // Prefer the MacBook keyboard so an attached external keyboard does not
        // unexpectedly become an application-status lamp. Some drivers omit the
        // Built-In property, so falling back to every keyboard keeps desktop and
        // older-device behavior possible instead of silently doing nothing.
        let builtInKeyboards = keyboards.filter(isBuiltIn)
        return (
            all: keyboards,
            targets: builtInKeyboards.isEmpty ? keyboards : builtInKeyboards
        )
    }

    private func keyboardServices(in services: CFArray) -> [IOHIDServiceClient] {
        (0..<CFArrayGetCount(services)).compactMap { index in
            guard let rawService = CFArrayGetValueAtIndex(services, index) else {
                return nil
            }
            let service = unsafeBitCast(rawService, to: IOHIDServiceClient.self)
            let conforms = IOHIDServiceClientConformsTo(
                service,
                Self.genericDesktopUsagePage,
                Self.keyboardUsage
            )
            return conforms != 0 ? service : nil
        }
    }

    private func isBuiltIn(_ service: IOHIDServiceClient) -> Bool {
        guard let property = IOHIDServiceClientCopyProperty(service, Self.builtInKey) else {
            return false
        }
        return (property as? NSNumber)?.boolValue == true
    }
}
