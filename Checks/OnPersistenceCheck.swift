import Darwin
import Foundation

@main
enum OnPersistenceCheck {
    static func main() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.first == "__capsled-check-interrupted-parent" {
            guard arguments.count == 2, let executableURL = Bundle.main.executableURL else {
                exit(64)
            }
            setenv("CAPSLED_CHECK_ON_DELAY_MS", "300", 1)
            let manager = try PersistentLEDOnProcessManager(
                runtimeDirectory: URL(fileURLWithPath: arguments[1]),
                executableURL: executableURL
            )
            _ = try manager.start()
            exit(0)
        }

        if arguments.first == PersistentLEDOnProcessManager.workerCommand {
            // Re-enter the real worker path with a fake controller. This lets the
            // parent check exercise Process launch, readiness, flock, signals,
            // and shutdown without touching keyboard hardware.
            let request = try PersistentLEDOnProcessManager.parseWorkerRequest(arguments)
            let status = PersistentLEDOnWorker(
                lockURL: request.lockURL,
                readinessURL: request.readinessURL,
                acknowledgementURL: request.acknowledgementURL,
                controller: AlwaysOnController()
            ).run()
            exit(status)
        }

        checkOnStartsPersistentMaintainer()
        checkFinalWritesFollowPersistentMaintainerStop()
        checkRunTakesOwnershipAfterPersistentMaintainerStop()
        checkObservedOffIsRepaired()
        try checkDetachedWorkerLifecycle()
        try checkRunOwnershipBlocksOtherCommands()
        try checkModeOwnershipBlocksRun()
        try checkConcurrentStopWaitsForStart()
        try checkInterruptedParentDoesNotOrphanWorker()
        try checkWorkerStopsAfterLockReplacement()
        try checkStalePIDIsNotSignalled()
        try checkWorkerArgumentValidation()

        print("Persistent On checks passed")
    }

    private static func checkOnStartsPersistentMaintainer() {
        let events = EventRecorder()
        let controller = RecordingController(events: events)
        let manager = RecordingPersistentOnManager(events: events)

        let status = CapsLEDApplication.execute(
            arguments: ["on"],
            controller: controller,
            persistentOnManager: manager
        )

        precondition(status == 0)
        precondition(
            events.values == ["start-persistent-on"],
            "on must delegate ownership to the persistent worker"
        )
    }

    private static func checkFinalWritesFollowPersistentMaintainerStop() {
        for mode in [LEDMode.off, .automatic] {
            let events = EventRecorder()
            let controller = RecordingController(events: events)
            let manager = RecordingPersistentOnManager(events: events)

            let status = CapsLEDApplication.execute(
                arguments: [mode.rawValue],
                controller: controller,
                persistentOnManager: manager
            )

            precondition(status == 0)
            precondition(
                events.values == [
                    "acquire-exclusive-ownership",
                    "set-\(mode.rawValue)",
                    "release-exclusive-ownership",
                ],
                "a final mode write must remain locked after the On worker drains"
            )
        }
    }

    private static func checkRunTakesOwnershipAfterPersistentMaintainerStop() {
        let events = EventRecorder()
        let controller = RecordingController(events: events)
        let manager = RecordingPersistentOnManager(events: events)

        let status = CapsLEDApplication.execute(
            arguments: ["run", "--", "/usr/bin/true"],
            controller: controller,
            persistentOnManager: manager
        )

        precondition(status == 0)
        precondition(
            events.values.filter { $0 != "read-led" }
                == [
                    "acquire-exclusive-ownership",
                    "set-on",
                    "set-auto",
                    "release-exclusive-ownership",
                ],
            "run must hold shared ownership through its final Auto write"
        )
    }

    private static func checkObservedOffIsRepaired() {
        let repaired = DispatchSemaphore(value: 0)
        let errors = EventRecorder()
        let controller = RepairRecordingController {
            repaired.signal()
        }
        let maintainer = LEDOnMaintainer(controller: controller) {
            errors.append($0)
        }

        maintainer.start()
        let result = repaired.wait(timeout: .now() + 1)
        maintainer.stopAndWait()

        precondition(result == .success, "an observed Off must be repaired promptly")
        precondition(controller.modes == [.on])
        precondition(errors.values.isEmpty)
    }

    private static func checkStalePIDIsNotSignalled() throws {
        let runtimeDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("capsled-check-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: runtimeDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: runtimeDirectory) }

        let lockURL = runtimeDirectory.appendingPathComponent("maintainer.lock")
        // The current process PID is intentionally dangerous test data. If stop
        // trusted stale file contents without first acquiring the advisory lock,
        // this check would terminate itself. An unlocked PID is only crash residue.
        try "\(ProcessInfo.processInfo.processIdentifier)\n".write(
            to: lockURL,
            atomically: true,
            encoding: .utf8
        )

        let manager = try PersistentLEDOnProcessManager(
            runtimeDirectory: runtimeDirectory,
            executableURL: URL(fileURLWithPath: "/usr/bin/true")
        )
        try manager.stop()

        let staleStateAfterStop = try String(contentsOf: lockURL, encoding: .utf8)
        precondition(staleStateAfterStop.isEmpty)
    }

    private static func checkDetachedWorkerLifecycle() throws {
        let runtimeDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("capsled-check-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: runtimeDirectory) }

        guard let executableURL = Bundle.main.executableURL else {
            preconditionFailure("the persistence check executable must be discoverable")
        }
        let manager = try PersistentLEDOnProcessManager(
            runtimeDirectory: runtimeDirectory,
            executableURL: executableURL
        )

        let firstStart = try manager.start()
        guard case let .started(result) = firstStart else {
            preconditionFailure("the first on must launch a detached worker")
        }
        precondition(result.successfulWrites == 1)
        let secondStart = try manager.start()
        precondition(
            secondStart == .alreadyRunning,
            "repeated on must reuse the single lock-owning worker"
        )

        try manager.stop()
        let lockURL = runtimeDirectory.appendingPathComponent("maintainer.lock")
        let stateAfterStop = try String(contentsOf: lockURL, encoding: .utf8)
        precondition(stateAfterStop.isEmpty, "stop must wait until worker cleanup completes")
    }

    private static func checkConcurrentStopWaitsForStart() throws {
        let runtimeDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("capsled-check-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: runtimeDirectory) }

        guard let executableURL = Bundle.main.executableURL else {
            preconditionFailure("the persistence check executable must be discoverable")
        }
        let manager = try PersistentLEDOnProcessManager(
            runtimeDirectory: runtimeDirectory,
            executableURL: executableURL
        )

        // Hold start inside the fake controller long enough for stop to collide
        // with the operation lock. The final empty worker state proves stop ran
        // after readiness, rather than returning early and allowing a late On.
        // 300 ms is long enough for stop to observe the operation lock (whose
        // first retry is 500 ms), while staying well below the worker readiness
        // budget even on a loaded CI runner.
        setenv("CAPSLED_CHECK_ON_DELAY_MS", "300", 1)
        defer { unsetenv("CAPSLED_CHECK_ON_DELAY_MS") }
        let startFinished = DispatchSemaphore(value: 0)
        let startResult = EventRecorder()
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                _ = try manager.start()
                startResult.append("started")
            } catch {
                startResult.append("error: \(error.localizedDescription)")
            }
            startFinished.signal()
        }

        let workerLockURL = runtimeDirectory.appendingPathComponent("maintainer.lock")
        precondition(
            waitForNonemptyFile(at: workerLockURL),
            "the delayed worker must acquire its ownership lock"
        )
        try manager.stop()
        precondition(startFinished.wait(timeout: .now() + 1) == .success)
        precondition(startResult.values == ["started"])
        let stateAfterStop = try String(contentsOf: workerLockURL, encoding: .utf8)
        precondition(stateAfterStop.isEmpty, "the colliding stop must be the final owner")
    }

    private static func checkRunOwnershipBlocksOtherCommands() throws {
        let runtimeDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("capsled-check-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: runtimeDirectory) }

        let runManager = try PersistentLEDOnProcessManager(
            runtimeDirectory: runtimeDirectory,
            executableURL: URL(fileURLWithPath: "/usr/bin/true")
        )
        let competingManager = try PersistentLEDOnProcessManager(
            runtimeDirectory: runtimeDirectory,
            executableURL: URL(fileURLWithPath: "/usr/bin/true")
        )
        let ownership = try runManager.acquireExclusiveOwnership()
        defer { ownership.release() }

        do {
            try competingManager.stop()
            preconditionFailure("a menu or CLI mode change must not interrupt run ownership")
        } catch PersistentLEDOnError.operationBusy {
            // Expected after the three bounded, jittered lock observations. The
            // competing command must report busy instead of writing Off/Auto or
            // starting a second maintainer while run is still repairing On.
        }

        ownership.release()
        try competingManager.stop()
    }

    private static func checkModeOwnershipBlocksRun() throws {
        let runtimeDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("capsled-check-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: runtimeDirectory) }

        let modeManager = try PersistentLEDOnProcessManager(
            runtimeDirectory: runtimeDirectory,
            executableURL: URL(fileURLWithPath: "/usr/bin/true")
        )
        let runManager = try PersistentLEDOnProcessManager(
            runtimeDirectory: runtimeDirectory,
            executableURL: URL(fileURLWithPath: "/usr/bin/true")
        )
        let controller = BlockingModeController()
        let coordinator = CapsLEDModeCoordinator(
            controller: controller,
            persistentOnManager: modeManager
        )
        let modeCompleted = DispatchSemaphore(value: 0)

        DispatchQueue.global(qos: .userInitiated).async {
            _ = try? coordinator.setMode(.off)
            modeCompleted.signal()
        }
        precondition(controller.writeStarted.wait(timeout: .now() + 1) == .success)

        do {
            _ = try runManager.acquireExclusiveOwnership()
            preconditionFailure("run must not begin before a final Off/Auto write finishes")
        } catch PersistentLEDOnError.operationBusy {
            // Expected: the slow final HID write still owns the operation lock.
        }

        controller.allowWriteToFinish.signal()
        precondition(modeCompleted.wait(timeout: .now() + 1) == .success)
        let runOwnership = try runManager.acquireExclusiveOwnership()
        runOwnership.release()
    }

    private static func checkWorkerStopsAfterLockReplacement() throws {
        let runtimeDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("capsled-check-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: runtimeDirectory) }

        guard let executableURL = Bundle.main.executableURL else {
            preconditionFailure("the persistence check executable must be discoverable")
        }
        let manager = try PersistentLEDOnProcessManager(
            runtimeDirectory: runtimeDirectory,
            executableURL: executableURL
        )
        _ = try manager.start()

        let workerLockURL = runtimeDirectory.appendingPathComponent("maintainer.lock")
        let pidText = try String(contentsOf: workerLockURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let workerPID = pid_t(pidText) else {
            preconditionFailure("the worker lock must contain its PID")
        }

        try FileManager.default.removeItem(at: workerLockURL)
        precondition(
            waitForProcessExit(workerPID),
            "a worker must exit when its lock path no longer names the held inode"
        )
    }

    private static func checkInterruptedParentDoesNotOrphanWorker() throws {
        let runtimeDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("capsled-check-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: runtimeDirectory) }

        guard let executableURL = Bundle.main.executableURL else {
            preconditionFailure("the persistence check executable must be discoverable")
        }
        let parent = Process()
        parent.executableURL = executableURL
        parent.arguments = ["__capsled-check-interrupted-parent", runtimeDirectory.path]
        parent.standardInput = FileHandle.nullDevice
        parent.standardOutput = FileHandle.nullDevice
        parent.standardError = FileHandle.nullDevice
        try parent.run()

        let workerLockURL = runtimeDirectory.appendingPathComponent("maintainer.lock")
        precondition(
            waitForNonemptyFile(at: workerLockURL),
            "the worker must start before its readiness-waiting parent is interrupted"
        )
        let pidText = try String(contentsOf: workerLockURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let workerPID = pid_t(pidText) else {
            preconditionFailure("the worker lock must contain its PID")
        }

        // Foundation launches the worker outside this parent's process group, so
        // terminating only the readiness-waiting parent reproduces Ctrl-C/SIGTERM
        // without accidentally delivering the signal to the worker as well.
        parent.terminate()
        precondition(
            waitForProcessExit(workerPID),
            "a worker without the parent's ownership ACK must restore Auto and exit"
        )
    }

    private static func waitForNonemptyFile(at url: URL) -> Bool {
        for attempt in 0..<3 {
            if let value = try? String(contentsOf: url, encoding: .utf8), !value.isEmpty {
                return true
            }
            sleepWithJitter(baseMicroseconds: 100_000, attempt: attempt)
        }
        // The third backoff is part of the retry budget, so observe once more
        // after it. Returning immediately after the sleep made loaded CI runners
        // fail even when the worker published readiness within the allowed time.
        guard let value = try? String(contentsOf: url, encoding: .utf8) else {
            return false
        }
        return !value.isEmpty
    }

    private static func waitForProcessExit(_ pid: pid_t) -> Bool {
        for attempt in 0..<3 {
            var status: Int32 = 0
            if waitpid(pid, &status, WNOHANG) == pid {
                return true
            }
            if kill(pid, 0) == -1, errno == ESRCH {
                return true
            }
            sleepWithJitter(baseMicroseconds: 500_000, attempt: attempt)
        }
        var status: Int32 = 0
        if waitpid(pid, &status, WNOHANG) == pid {
            return true
        }
        return kill(pid, 0) == -1 && errno == ESRCH
    }

    private static func sleepWithJitter(baseMicroseconds: useconds_t, attempt: Int) {
        let delay = UInt64(baseMicroseconds) << UInt64(attempt)
        let jitter = UInt64.random(in: 0...(delay / 2))
        usleep(useconds_t(delay + jitter))
    }

    private static func checkWorkerArgumentValidation() throws {
        let request = try PersistentLEDOnProcessManager.parseWorkerRequest([
            PersistentLEDOnProcessManager.workerCommand,
            "/tmp/capsled.lock",
            "/tmp/capsled.ready",
            "/tmp/capsled.ack",
        ])
        precondition(request.lockURL.path == "/tmp/capsled.lock")
        precondition(request.readinessURL.path == "/tmp/capsled.ready")
        precondition(request.acknowledgementURL.path == "/tmp/capsled.ack")

        do {
            _ = try PersistentLEDOnProcessManager.parseWorkerRequest([
                PersistentLEDOnProcessManager.workerCommand,
            ])
            preconditionFailure("partial worker state paths must be rejected")
        } catch PersistentLEDOnError.invalidWorkerArguments {
            // Expected: reject the hidden command before it can open the lock or
            // create an HID controller for malformed worker state.
        }
    }
}

private final class EventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var values: [String] {
        lock.withLock { storage }
    }

    func append(_ value: String) {
        lock.withLock { storage.append(value) }
    }
}

private final class RecordingController: CapsLockLEDControlling {
    private let events: EventRecorder

    init(events: EventRecorder) {
        self.events = events
    }

    func setMode(_ mode: LEDMode) throws -> LEDUpdateResult {
        events.append("set-\(mode.rawValue)")
        return LEDUpdateResult(
            matchedKeyboards: 1,
            targetedKeyboards: 1,
            successfulWrites: 1
        )
    }

    func isLEDOn() throws -> Bool {
        events.append("read-led")
        return true
    }
}

private final class RecordingPersistentOnManager: PersistentLEDOnManaging {
    private let events: EventRecorder

    init(events: EventRecorder) {
        self.events = events
    }

    func start() throws -> PersistentLEDOnStartResult {
        events.append("start-persistent-on")
        return .started(
            LEDUpdateResult(
                matchedKeyboards: 1,
                targetedKeyboards: 1,
                successfulWrites: 1
            )
        )
    }

    func stop() throws {
        events.append("stop-persistent-on")
    }

    func acquireExclusiveOwnership() throws -> PersistentLEDOwnership {
        events.append("acquire-exclusive-ownership")
        return RecordingOwnership(events: events)
    }
}

private final class RecordingOwnership: PersistentLEDOwnership {
    private let events: EventRecorder
    private var isReleased = false

    init(events: EventRecorder) {
        self.events = events
    }

    func release() {
        guard !isReleased else { return }
        isReleased = true
        events.append("release-exclusive-ownership")
    }
}

private final class BlockingModeController: CapsLockLEDControlling, @unchecked Sendable {
    let writeStarted = DispatchSemaphore(value: 0)
    let allowWriteToFinish = DispatchSemaphore(value: 0)

    func setMode(_ mode: LEDMode) throws -> LEDUpdateResult {
        writeStarted.signal()
        _ = allowWriteToFinish.wait(timeout: .now() + 3)
        return LEDUpdateResult(
            matchedKeyboards: 1,
            targetedKeyboards: 1,
            successfulWrites: 1
        )
    }

    func isLEDOn() throws -> Bool { true }
}

private final class RepairRecordingController: CapsLockLEDControlling, @unchecked Sendable {
    private let lock = NSLock()
    private let onRepair: () -> Void
    private var recordedModes: [LEDMode] = []

    init(onRepair: @escaping () -> Void) {
        self.onRepair = onRepair
    }

    var modes: [LEDMode] {
        lock.withLock { recordedModes }
    }

    func setMode(_ mode: LEDMode) throws -> LEDUpdateResult {
        lock.withLock { recordedModes.append(mode) }
        if mode == .on {
            onRepair()
        }
        return LEDUpdateResult(
            matchedKeyboards: 1,
            targetedKeyboards: 1,
            successfulWrites: 1
        )
    }

    func isLEDOn() throws -> Bool {
        false
    }
}

private final class AlwaysOnController: CapsLockLEDControlling {
    func setMode(_ mode: LEDMode) throws -> LEDUpdateResult {
        if mode == .on,
           let delay = ProcessInfo.processInfo.environment["CAPSLED_CHECK_ON_DELAY_MS"],
           let milliseconds = useconds_t(delay) {
            usleep(milliseconds * 1_000)
        }
        return LEDUpdateResult(
            matchedKeyboards: 1,
            targetedKeyboards: 1,
            successfulWrites: 1
        )
    }

    func isLEDOn() throws -> Bool {
        true
    }
}
