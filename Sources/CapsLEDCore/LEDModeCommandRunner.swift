import Foundation

public protocol CapsLEDModeSetting: AnyObject {
    func setMode(_ mode: LEDMode) throws -> CapsLEDModeOperationResult
}

extension CapsLEDModeCoordinator: CapsLEDModeSetting {}

/// Serializes potentially waiting ownership changes away from a UI thread,
/// then delivers each completion on the caller-selected callback queue.
public final class LEDModeCommandRunner {
    public typealias Completion = (Result<CapsLEDModeOperationResult, Error>) -> Void

    private let coordinator: CapsLEDModeSetting
    private let commandQueue: DispatchQueue
    private let callbackQueue: DispatchQueue

    public init(
        coordinator: CapsLEDModeSetting,
        commandQueue: DispatchQueue = DispatchQueue(
            label: "io.github.sol-momma.capsled.mode-commands",
            qos: .userInitiated
        ),
        callbackQueue: DispatchQueue = .main
    ) {
        self.coordinator = coordinator
        self.commandQueue = commandQueue
        self.callbackQueue = callbackQueue
    }

    public func apply(_ mode: LEDMode, completion: @escaping Completion) {
        commandQueue.async { [coordinator, callbackQueue] in
            let result = Result { try coordinator.setMode(mode) }
            callbackQueue.async {
                completion(result)
            }
        }
    }

    public func prepareForTermination(completion: @escaping Completion) {
        // Quitting is another ownership change, but naming it separately keeps
        // the Auto-on-exit policy explicit and independently testable instead of
        // hiding a safety behavior in the AppKit delegate's control flow.
        apply(.automatic, completion: completion)
    }
}
