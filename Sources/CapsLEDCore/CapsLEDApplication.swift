import Darwin
import Foundation

public enum CapsLEDApplication {
    private static let usageError: Int32 = 64
    private static let unavailableError: Int32 = 69

    public static func execute(
        arguments: [String],
        controller: CapsLockLEDControlling = EventSystemCapsLockLEDController()
    ) -> Int32 {
        if arguments.first == PersistentLEDOnProcessManager.workerCommand {
            do {
                let request = try PersistentLEDOnProcessManager.parseWorkerRequest(arguments)
                return PersistentLEDOnWorker(
                    lockURL: request.lockURL,
                    readinessURL: request.readinessURL,
                    acknowledgementURL: request.acknowledgementURL,
                    controller: controller
                ).run()
            } catch {
                writeError("capsled: \(error.localizedDescription)")
                return unavailableError
            }
        }

        do {
            let persistentOnManager = try PersistentLEDOnProcessManager()
            return execute(
                arguments: arguments,
                controller: controller,
                persistentOnManager: persistentOnManager,
                watcherFactory: { RawHIDPhysicalCapsLockWatcher() },
                terminationWaiterFactory: { TerminationSignalWaiter() }
            )
        } catch {
            writeError("capsled: \(error.localizedDescription)")
            return unavailableError
        }
    }

    static func execute(
        arguments: [String],
        controller: CapsLockLEDControlling,
        persistentOnManager: PersistentLEDOnManaging = InactivePersistentLEDOnManager(),
        watcherFactory: () -> PhysicalCapsLockWatching = { RawHIDPhysicalCapsLockWatcher() },
        terminationWaiterFactory: () -> TerminationWaiting = { TerminationSignalWaiter() }
    ) -> Int32 {
        do {
            switch try CLIParser.parse(arguments) {
            case .help:
                print(CLIParser.usage)
                return 0
            case let .set(mode):
                if mode == .on {
                    switch try persistentOnManager.start() {
                    case let .started(result):
                        printResult(mode: mode, result: result)
                    case .alreadyRunning:
                        print("capsled: already forced on (maintainer is running)")
                    }
                    return 0
                }

                // Stop and drain the persistent On repair before writing Off or
                // Auto. Reversing these operations would let an in-flight repair
                // relight the LED after this command has reported success.
                try persistentOnManager.stop()
                let result = try controller.setMode(mode)
                printResult(mode: mode, result: result)
                return 0
            case let .run(command):
                try persistentOnManager.stop()
                return try run(command, controller: controller)
            case .watch:
                // `watch` temporarily owns the LED and always restores Auto on
                // exit. Stop a detached `on` worker before taking the baseline;
                // otherwise both processes could race to rewrite the same HID
                // value and the first physical press would appear ineffective.
                try persistentOnManager.stop()
                return try watch(
                    controller: controller,
                    watcher: watcherFactory(),
                    terminationWaiter: terminationWaiterFactory()
                )
            }
        } catch let error as CLIParseError {
            writeError("capsled: \(error.localizedDescription)\n\n\(CLIParser.usage)")
            return usageError
        } catch let error as PhysicalCapsLockWatcherError {
            writeError("capsled: \(error.localizedDescription)")
            return error.exitStatus
        } catch {
            writeError("capsled: \(error.localizedDescription)")
            return unavailableError
        }
    }

    private static func watch(
        controller: CapsLockLEDControlling,
        watcher: PhysicalCapsLockWatching,
        terminationWaiter: TerminationWaiting
    ) throws -> Int32 {
        let coordinator = LEDWatchCoordinator(
            controller: controller,
            reportResult: { mode, result in
                printResult(mode: mode, result: result)
            },
            reportError: { message in
                writeError(message)
            }
        )

        var watcherPrepared = false
        var ownsLED = false
        defer {
            // Stop raw input first and wait for its callbacks, then drain every
            // accepted LED toggle before Auto. Reversing this order could let a
            // late queued On write replace the cleanup value.
            if watcherPrepared {
                watcher.stopAndWait()
            }
            coordinator.stopAndWait()
            if ownsLED {
                restoreAutomatic(using: controller)
            }
        }

        // Permission and device discovery finish before the LED snapshot, but
        // raw callbacks do not start yet. This defines an unambiguous monitoring
        // boundary: the snapshot is the baseline immediately before activation,
        // so a Caps press cannot both change that baseline and be applied again.
        try watcher.prepare()
        watcherPrepared = true

        // Seed from the effective LED state without writing it. `watch` should
        // change the LED only after a physical Caps Lock press; an existing
        // manual On override must not be cleared merely by starting monitoring.
        let initialMode: LEDMode = try ExternalServiceRetry.perform {
            try controller.isLEDOn() ? .on : .off
        }
        ownsLED = true
        coordinator.start(initialMode: initialMode)
        watcher.activate {
            coordinator.toggle()
        }

        print("capsled: watching physical Caps Lock presses (press Control-C to stop)")
        let signalNumber = terminationWaiter.wait()
        return 128 + signalNumber
    }

    private static func run(
        _ command: [String],
        controller: CapsLockLEDControlling
    ) throws -> Int32 {
        let onResult = try controller.setMode(.on)
        printResult(mode: .on, result: onResult)

        let maintainer = LEDOnMaintainer(controller: controller) { message in
            writeError(message)
        }
        maintainer.start()

        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        child.arguments = command

        do {
            try child.run()
        } catch {
            // Stop and drain maintenance before restoring Auto. This ordering
            // is required even on startup failure because the timer starts as
            // soon as the initial On write succeeds.
            maintainer.stopAndWait()
            restoreAutomatic(using: controller)
            throw error
        }

        let signalForwarder = SignalForwarder(child: child)
        child.waitUntilExit()
        signalForwarder.cancel()

        maintainer.stopAndWait()
        restoreAutomatic(using: controller)

        switch child.terminationReason {
        case .exit:
            return child.terminationStatus
        case .uncaughtSignal:
            return 128 + child.terminationStatus
        @unknown default:
            return child.terminationStatus
        }
    }

    private static func restoreAutomatic(using controller: CapsLockLEDControlling) {
        do {
            let restoreResult = try controller.setMode(.automatic)
            printResult(mode: .automatic, result: restoreResult)
        } catch {
            // Preserve the child command's status, but make the recovery command
            // explicit. SIGKILL and power loss have the same limitation because
            // no process can execute cleanup after it has been forcibly removed.
            writeError("capsled: could not restore automatic LED control: \(error.localizedDescription)")
            writeError("capsled: run `capsled auto` to recover")
        }
    }

    private static func printResult(mode: LEDMode, result: LEDUpdateResult) {
        let description: String
        switch mode {
        case .on: description = "forced on"
        case .off: description = "forced off"
        case .automatic: description = "returned to macOS"
        }
        print(
            "capsled: \(description) "
                + "(keyboards=\(result.matchedKeyboards) "
                + "targets=\(result.targetedKeyboards) "
                + "writes=\(result.successfulWrites))"
        )
    }

    private static func writeError(_ message: String) {
        guard let data = "\(message)\n".data(using: .utf8) else { return }
        try? FileHandle.standardError.write(contentsOf: data)
    }
}

/// Test-only default for the internal execution seam. Production entry points
/// always inject `PersistentLEDOnProcessManager`; keeping the inert default here
/// lets lifecycle checks isolate `watch` without creating per-user lock files or
/// detached processes as a side effect of a fake-backend test.
struct InactivePersistentLEDOnManager: PersistentLEDOnManaging {
    func start() throws -> PersistentLEDOnStartResult {
        .started(
            LEDUpdateResult(
                matchedKeyboards: 0,
                targetedKeyboards: 0,
                successfulWrites: 0
            )
        )
    }

    func stop() throws {}
}

private final class SignalForwarder {
    private let child: Process
    private var sources: [DispatchSourceSignal] = []

    init(child: Process) {
        self.child = child

        // The wrapper ignores termination signals only after the child starts,
        // then forwards them to the child. This lets waitUntilExit return and the
        // normal Auto restoration run. SIGKILL remains intentionally impossible
        // to handle; `capsled auto` is the documented recovery path.
        for signalNumber in [SIGINT, SIGTERM] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(
                signal: signalNumber,
                queue: DispatchQueue.global(qos: .userInitiated)
            )
            source.setEventHandler { [weak self] in
                guard let self, self.child.isRunning else { return }
                kill(self.child.processIdentifier, signalNumber)
            }
            source.resume()
            sources.append(source)
        }
    }

    func cancel() {
        sources.forEach { $0.cancel() }
        sources.removeAll()
    }
}
