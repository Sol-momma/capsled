import Darwin
import Foundation

@main
enum WatchBehaviorCheck {
    static func main() throws {
        try checkParser()
        checkPressEdges()
        checkWatchLifecycle()
        checkSnapshotPrecedesActivation()
        checkInitialOnStateIsNotChangedBeforePress()
        checkActivationPressIsHandled()
        checkInFlightPressIsDrainedBeforeAuto()
        checkPermissionFailure()
        checkInitialReadFailureStopsWatcher()
        checkNonWatchIsolation()
        checkRunRegression()
        checkStartupRetryPolicy()
        checkRepeatedFailurePolicy()
        print("Watch behavior checks passed")
    }

    private static func checkParser() throws {
        let watch = try CLIParser.parse(["watch"])
        precondition(watch == .watch)

        do {
            _ = try CLIParser.parse(["watch", "unexpected"])
            preconditionFailure("watch arguments must fail")
        } catch is CLIParseError {
            // Expected: the experimental command has one strict behavior, so a
            // typo cannot silently select a different monitoring policy.
        }
    }

    private static func checkPressEdges() {
        let builtIn = DeviceToken()
        let external = DeviceToken()
        var state = CapsLockPressState()

        precondition(state.observe(device: builtIn, isPressed: true))
        precondition(!state.observe(device: builtIn, isPressed: true))
        precondition(state.observe(device: external, isPressed: true))
        precondition(!state.observe(device: builtIn, isPressed: false))
        precondition(state.observe(device: builtIn, isPressed: true))
        precondition(!state.observe(device: external, isPressed: false))
    }

    private static func checkWatchLifecycle() {
        let controller = RecordingController()
        let watcher = FakeWatcher()
        let waiter = FakeTerminationWaiter {
            watcher.press()
            watcher.press()
            return SIGINT
        }

        let status = CapsLEDApplication.execute(
            arguments: ["watch"],
            controller: controller,
            watcherFactory: { watcher },
            terminationWaiterFactory: { waiter }
        )

        precondition(status == 128 + SIGINT)
        precondition(controller.attemptedModes == [.on, .off, .automatic])
        precondition(watcher.didStop)
    }

    private static func checkActivationPressIsHandled() {
        let controller = RecordingController()
        let watcher = FakeWatcher(pressOnStart: true)

        let status = CapsLEDApplication.execute(
            arguments: ["watch"],
            controller: controller,
            watcherFactory: { watcher },
            terminationWaiterFactory: { FakeTerminationWaiter { SIGINT } }
        )

        precondition(status == 128 + SIGINT)
        precondition(controller.attemptedModes == [.on, .automatic])
    }

    private static func checkSnapshotPrecedesActivation() {
        let log = LifecycleLog()
        let controller = RecordingController(
            onRead: { log.append("read") },
            onSet: { log.append("set:\($0.rawValue)") }
        )
        let persistentOnManager = FakePersistentOnManager(
            onAcquire: { log.append("acquire-exclusive-ownership") },
            onRelease: { log.append("release-exclusive-ownership") }
        )
        let watcher = FakeWatcher(onLifecycle: { log.append($0) })

        _ = CapsLEDApplication.execute(
            arguments: ["watch"],
            controller: controller,
            persistentOnManager: persistentOnManager,
            watcherFactory: { watcher },
            terminationWaiterFactory: { FakeTerminationWaiter { SIGINT } }
        )

        precondition(
            log.values == [
                "acquire-exclusive-ownership",
                "prepare",
                "read",
                "activate",
                "stop",
                "set:auto",
                "release-exclusive-ownership",
            ]
        )
    }

    private static func checkInitialOnStateIsNotChangedBeforePress() {
        let controller = RecordingController(initialIsOn: true)
        let watcher = FakeWatcher()
        let waiter = FakeTerminationWaiter {
            watcher.press()
            return SIGINT
        }

        _ = CapsLEDApplication.execute(
            arguments: ["watch"],
            controller: controller,
            watcherFactory: { watcher },
            terminationWaiterFactory: { waiter }
        )

        // No startup On write is expected. The only user-state write is the
        // first press toggling the inherited On state to Off, followed by Auto.
        precondition(controller.attemptedModes == [.off, .automatic])
    }

    private static func checkInFlightPressIsDrainedBeforeAuto() {
        let controller = RecordingController()
        let watcher = FakeWatcher(pressOnStop: true)

        _ = CapsLEDApplication.execute(
            arguments: ["watch"],
            controller: controller,
            watcherFactory: { watcher },
            terminationWaiterFactory: { FakeTerminationWaiter { SIGINT } }
        )

        // FakeWatcher emits from stopAndWait to model a callback already in
        // flight. Auto must remain last after the coordinator drains that press.
        precondition(controller.attemptedModes == [.on, .automatic])
    }

    private static func checkPermissionFailure() {
        let controller = RecordingController()
        let watcher = FakeWatcher(startError: .inputMonitoringPermissionRequired)

        let status = CapsLEDApplication.execute(
            arguments: ["watch"],
            controller: controller,
            watcherFactory: { watcher },
            terminationWaiterFactory: { FakeTerminationWaiter { SIGINT } }
        )

        precondition(status == 77)
        precondition(controller.attemptedModes.isEmpty)
        precondition(!watcher.didStop)
    }

    private static func checkInitialReadFailureStopsWatcher() {
        let controller = RecordingController(readFailuresRemaining: 3)
        let watcher = FakeWatcher()

        let status = CapsLEDApplication.execute(
            arguments: ["watch"],
            controller: controller,
            watcherFactory: { watcher },
            terminationWaiterFactory: { FakeTerminationWaiter { SIGINT } }
        )

        precondition(status == 69)
        precondition(watcher.didStop)
        precondition(controller.readAttempts == 3)
        precondition(controller.attemptedModes.isEmpty)
    }

    private static func checkNonWatchIsolation() {
        let controller = RecordingController()
        var madeWatcher = false

        let status = CapsLEDApplication.execute(
            arguments: ["off"],
            controller: controller,
            watcherFactory: {
                madeWatcher = true
                return FakeWatcher()
            },
            terminationWaiterFactory: { FakeTerminationWaiter { SIGINT } }
        )

        precondition(status == 0)
        precondition(!madeWatcher)
        precondition(controller.attemptedModes == [.off])
    }

    private static func checkRunRegression() {
        let controller = RecordingController()
        let status = CapsLEDApplication.execute(
            arguments: ["run", "--", "/usr/bin/true"],
            controller: controller,
            watcherFactory: {
                preconditionFailure("run must not create a watcher")
            },
            terminationWaiterFactory: {
                preconditionFailure("run must not create a signal waiter")
            }
        )

        precondition(status == 0)
        precondition(controller.attemptedModes == [.on, .automatic])
    }

    private static func checkStartupRetryPolicy() {
        var attempt = 0
        var jitterRanges: [ClosedRange<UInt64>] = []
        var sleepDurations: [UInt64] = []

        let value = try? ExternalServiceRetry.perform(
            baseNanoseconds: 100,
            jitter: { range in
                jitterRanges.append(range)
                return range.upperBound
            },
            sleep: { sleepDurations.append($0) }
        ) {
            attempt += 1
            if attempt < 3 {
                throw FakeControllerError.rejected
            }
            return 42
        }

        precondition(value == 42)
        precondition(attempt == 3)
        precondition(jitterRanges == [0...50, 0...100])
        precondition(sleepDurations == [150, 300])
    }

    private static func checkRepeatedFailurePolicy() {
        let stopped = DispatchSemaphore(value: 0)
        let controller = RecordingController(failingMode: .on)
        var unexpectedlyReportedSuccess = false
        var reportedError = ""
        let coordinator = LEDWatchCoordinator(
            controller: controller,
            reportResult: { _, _ in
                unexpectedlyReportedSuccess = true
            },
            reportError: { message in
                reportedError = message
                stopped.signal()
            },
            retryBaseNanoseconds: 100_000,
            retryJitter: { _ in 0 }
        )

        coordinator.start(initialMode: .off)
        coordinator.toggle()
        let waitResult = stopped.wait(timeout: .now() + 1)
        coordinator.stopAndWait()

        precondition(waitResult == .success)
        precondition(!unexpectedlyReportedSuccess)
        precondition(reportedError.contains("stopped after 3 repeated failures"))
        precondition(controller.attemptedModes == [.on, .on, .on])
    }
}

private final class DeviceToken {}

private final class LifecycleLog {
    private let lock = NSLock()
    private var entries: [String] = []

    var values: [String] {
        lock.withLock { entries }
    }

    func append(_ entry: String) {
        lock.withLock { entries.append(entry) }
    }
}

private enum FakeControllerError: LocalizedError {
    case rejected

    var errorDescription: String? { "simulated HID rejection" }
}

private final class RecordingController: CapsLockLEDControlling {
    private let lock = NSLock()
    private let failingMode: LEDMode?
    private var modes: [LEDMode] = []
    private var isOn = false
    private var remainingReadFailures: Int
    private var reads = 0
    private let onRead: () -> Void
    private let onSet: (LEDMode) -> Void

    init(
        failingMode: LEDMode? = nil,
        readFailuresRemaining: Int = 0,
        initialIsOn: Bool = false,
        onRead: @escaping () -> Void = {},
        onSet: @escaping (LEDMode) -> Void = { _ in }
    ) {
        self.failingMode = failingMode
        remainingReadFailures = readFailuresRemaining
        isOn = initialIsOn
        self.onRead = onRead
        self.onSet = onSet
    }

    var attemptedModes: [LEDMode] {
        lock.withLock { modes }
    }

    var readAttempts: Int {
        lock.withLock { reads }
    }

    func setMode(_ mode: LEDMode) throws -> LEDUpdateResult {
        try lock.withLock {
            modes.append(mode)
            onSet(mode)
            if mode == failingMode {
                throw FakeControllerError.rejected
            }
            isOn = mode == .on
            return LEDUpdateResult(
                matchedKeyboards: 1,
                targetedKeyboards: 1,
                successfulWrites: 1
            )
        }
    }

    func isLEDOn() throws -> Bool {
        try lock.withLock {
            reads += 1
            onRead()
            if remainingReadFailures > 0 {
                remainingReadFailures -= 1
                throw FakeControllerError.rejected
            }
            return isOn
        }
    }
}

private final class FakeWatcher: PhysicalCapsLockWatching {
    private let startError: PhysicalCapsLockWatcherError?
    private let pressOnStart: Bool
    private let pressOnStop: Bool
    private let onLifecycle: (String) -> Void
    private var onPress: (() -> Void)?
    private(set) var didStop = false

    init(
        startError: PhysicalCapsLockWatcherError? = nil,
        pressOnStart: Bool = false,
        pressOnStop: Bool = false,
        onLifecycle: @escaping (String) -> Void = { _ in }
    ) {
        self.startError = startError
        self.pressOnStart = pressOnStart
        self.pressOnStop = pressOnStop
        self.onLifecycle = onLifecycle
    }

    func prepare() throws {
        onLifecycle("prepare")
        if let startError {
            throw startError
        }
    }

    func activate(onPress: @escaping () -> Void) {
        onLifecycle("activate")
        self.onPress = onPress
        if pressOnStart {
            onPress()
        }
    }

    func stopAndWait() {
        onLifecycle("stop")
        didStop = true
        if pressOnStop {
            onPress?()
        }
        onPress = nil
    }

    func press() {
        onPress?()
    }
}

private final class FakeTerminationWaiter: TerminationWaiting {
    private let result: () -> Int32

    init(result: @escaping () -> Int32) {
        self.result = result
    }

    func wait() -> Int32 {
        result()
    }
}

private final class FakePersistentOnManager: PersistentLEDOnManaging {
    private let onAcquire: () -> Void
    private let onRelease: () -> Void

    init(onAcquire: @escaping () -> Void, onRelease: @escaping () -> Void) {
        self.onAcquire = onAcquire
        self.onRelease = onRelease
    }

    func start() throws -> PersistentLEDOnStartResult {
        preconditionFailure("watch must never start the persistent On maintainer")
    }

    func stop() throws {
        preconditionFailure("watch must reserve ownership instead of calling stop directly")
    }

    func acquireExclusiveOwnership() throws -> PersistentLEDOwnership {
        onAcquire()
        return FakePersistentLEDOwnership(onRelease: onRelease)
    }
}

private final class FakePersistentLEDOwnership: PersistentLEDOwnership {
    private let onRelease: () -> Void

    init(onRelease: @escaping () -> Void) {
        self.onRelease = onRelease
    }

    func release() {
        onRelease()
    }
}
