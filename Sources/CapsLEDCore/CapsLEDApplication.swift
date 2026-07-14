import Darwin
import Foundation

public enum CapsLEDApplication {
    private static let usageError: Int32 = 64
    private static let unavailableError: Int32 = 69

    public static func execute(
        arguments: [String],
        controller: CapsLockLEDControlling = EventSystemCapsLockLEDController()
    ) -> Int32 {
        if let workerStatus = executeWorkerIfRequested(
            arguments: arguments,
            controller: controller
        ) {
            return workerStatus
        }

        do {
            let persistentOnManager = try PersistentLEDOnProcessManager()
            return execute(
                arguments: arguments,
                controller: controller,
                persistentOnManager: persistentOnManager
            )
        } catch {
            writeError("capsled: \(error.localizedDescription)")
            return unavailableError
        }
    }

    /// Runs the hidden persistent-On worker before a CLI or AppKit entry point
    /// initializes its ordinary user interface. Returning nil means the process
    /// was not launched as a worker and should continue normal startup.
    public static func executeWorkerIfRequested(
        arguments: [String],
        controller: CapsLockLEDControlling? = nil
    ) -> Int32? {
        guard arguments.first == PersistentLEDOnProcessManager.workerCommand else {
            return nil
        }

        do {
            let request = try PersistentLEDOnProcessManager.parseWorkerRequest(arguments)
            return PersistentLEDOnWorker(
                lockURL: request.lockURL,
                readinessURL: request.readinessURL,
                acknowledgementURL: request.acknowledgementURL,
                // A normal GUI launch should not create and immediately discard
                // an IOHID client just to discover that it is not a worker. Delay
                // the default controller until the hidden mode is confirmed.
                controller: controller ?? EventSystemCapsLockLEDController()
            ).run()
        } catch {
            writeError("capsled: \(error.localizedDescription)")
            return unavailableError
        }
    }

    static func execute(
        arguments: [String],
        controller: CapsLockLEDControlling,
        persistentOnManager: PersistentLEDOnManaging
    ) -> Int32 {
        do {
            let coordinator = CapsLEDModeCoordinator(
                controller: controller,
                persistentOnManager: persistentOnManager
            )
            switch try CLIParser.parse(arguments) {
            case .help:
                print(CLIParser.usage)
                return 0
            case let .set(mode):
                switch try coordinator.setMode(mode) {
                case let .updated(result):
                    printResult(mode: mode, result: result)
                case .alreadyOn:
                    print("capsled: already forced on (maintainer is running)")
                }
                return 0
            case let .run(command):
                let ownership = try coordinator.acquireRunOwnership()
                defer { ownership.release() }
                return try run(command, controller: controller)
            }
        } catch let error as CLIParseError {
            writeError("capsled: \(error.localizedDescription)\n\n\(CLIParser.usage)")
            return usageError
        } catch {
            writeError("capsled: \(error.localizedDescription)")
            return unavailableError
        }
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
