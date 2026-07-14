import Foundation

@main
enum MenuBarCommandCheck {
    static func main() {
        checkCommandsAreAsynchronousAndSerialized()
        checkTerminationRequestsAutomaticMode()
        print("Menu-bar command checks passed")
    }

    private static func checkCommandsAreAsynchronousAndSerialized() {
        let coordinator = BlockingCoordinator()
        let callbacks = DispatchQueue(label: "capsled-check.menu-callbacks")
        let runner = LEDModeCommandRunner(
            coordinator: coordinator,
            callbackQueue: callbacks
        )
        let firstCompleted = DispatchSemaphore(value: 0)
        let secondCompleted = DispatchSemaphore(value: 0)

        runner.apply(.on) { _ in firstCompleted.signal() }
        precondition(coordinator.firstActionStarted.wait(timeout: .now() + 1) == .success)

        // The first fake HID call stays blocked while apply returns immediately.
        // Submitting Off now proves the serial queue cannot overlap a second
        // ownership transition with the still-running On operation.
        runner.apply(.off) { _ in secondCompleted.signal() }
        precondition(coordinator.modes == [.on])

        coordinator.allowFirstActionToFinish.signal()
        precondition(firstCompleted.wait(timeout: .now() + 1) == .success)
        precondition(secondCompleted.wait(timeout: .now() + 1) == .success)
        precondition(coordinator.modes == [.on, .off])
    }

    private static func checkTerminationRequestsAutomaticMode() {
        let coordinator = RecordingCoordinator()
        let callbacks = DispatchQueue(label: "capsled-check.termination-callbacks")
        let runner = LEDModeCommandRunner(
            coordinator: coordinator,
            callbackQueue: callbacks
        )
        let completed = DispatchSemaphore(value: 0)

        runner.prepareForTermination { result in
            precondition((try? result.get()) != nil)
            completed.signal()
        }

        precondition(completed.wait(timeout: .now() + 1) == .success)
        precondition(coordinator.modes == [.automatic])
    }
}

private final class BlockingCoordinator: CapsLEDModeSetting, @unchecked Sendable {
    let firstActionStarted = DispatchSemaphore(value: 0)
    let allowFirstActionToFinish = DispatchSemaphore(value: 0)

    private let lock = NSLock()
    private var storage: [LEDMode] = []

    var modes: [LEDMode] {
        lock.withLock { storage }
    }

    func setMode(_ mode: LEDMode) throws -> CapsLEDModeOperationResult {
        lock.withLock { storage.append(mode) }
        if mode == .on {
            firstActionStarted.signal()
            _ = allowFirstActionToFinish.wait(timeout: .now() + 1)
        }
        return .updated(Self.updateResult)
    }

    private static let updateResult = LEDUpdateResult(
        matchedKeyboards: 1,
        targetedKeyboards: 1,
        successfulWrites: 1
    )
}

private final class RecordingCoordinator: CapsLEDModeSetting, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [LEDMode] = []

    var modes: [LEDMode] {
        lock.withLock { storage }
    }

    func setMode(_ mode: LEDMode) throws -> CapsLEDModeOperationResult {
        lock.withLock { storage.append(mode) }
        return .updated(
            LEDUpdateResult(
                matchedKeyboards: 1,
                targetedKeyboards: 1,
                successfulWrites: 1
            )
        )
    }
}
