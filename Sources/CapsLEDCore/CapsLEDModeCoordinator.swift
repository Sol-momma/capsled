import Foundation

public enum CapsLEDModeOperationResult: Equatable {
    case updated(LEDUpdateResult)
    case alreadyOn
}

/// Coordinates ownership changes shared by the CLI and menu bar application.
///
/// Persistent On is owned by the existing detached worker. Off and Auto must
/// stop and drain that worker before their final HID write; otherwise a repair
/// already in flight could relight the LED after the UI reports success.
public final class CapsLEDModeCoordinator {
    private let controller: CapsLockLEDControlling
    private let persistentOnManager: PersistentLEDOnManaging

    public convenience init(
        controller: CapsLockLEDControlling = EventSystemCapsLockLEDController()
    ) throws {
        try self.init(
            controller: controller,
            persistentOnManager: PersistentLEDOnProcessManager()
        )
    }

    init(
        controller: CapsLockLEDControlling,
        persistentOnManager: PersistentLEDOnManaging
    ) {
        self.controller = controller
        self.persistentOnManager = persistentOnManager
    }

    public func setMode(_ mode: LEDMode) throws -> CapsLEDModeOperationResult {
        if mode == .on {
            switch try persistentOnManager.start() {
            case let .started(result):
                return .updated(result)
            case .alreadyRunning:
                return .alreadyOn
            }
        }

        let ownership = try persistentOnManager.acquireExclusiveOwnership()
        defer { ownership.release() }
        return .updated(try controller.setMode(mode))
    }

    func acquireRunOwnership() throws -> PersistentLEDOwnership {
        try persistentOnManager.acquireExclusiveOwnership()
    }
}
