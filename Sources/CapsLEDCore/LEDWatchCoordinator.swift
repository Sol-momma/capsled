import Foundation

/// Owns the desired LED state while `capsled watch` is active.
///
/// Raw HID callbacks enqueue a toggle here instead of touching the controller
/// directly. The serial queue gives presses a total order and lets shutdown
/// drain every accepted press before returning LED ownership to macOS.
final class LEDWatchCoordinator {
    private static let repeatedFailureLimit = 3
    private static let defaultRetryBaseNanoseconds: UInt64 = 25_000_000

    private let controller: CapsLockLEDControlling
    private let maintainer: LEDOnMaintainer
    private let reportResult: (LEDMode, LEDUpdateResult) -> Void
    private let reportError: (String) -> Void
    private let retryBaseNanoseconds: UInt64
    private let retryJitter: (ClosedRange<UInt64>) -> UInt64
    private let queue = DispatchQueue(label: "capsled.watch-led-state")

    private var isActive = false
    private var isStopped = false
    private var isHalted = false
    private var desiredMode = LEDMode.off
    private var generation: UInt64 = 0
    private var lastFailureSignature: String?
    private var repeatedFailureCount = 0

    init(
        controller: CapsLockLEDControlling,
        reportResult: @escaping (LEDMode, LEDUpdateResult) -> Void,
        reportError: @escaping (String) -> Void,
        retryBaseNanoseconds: UInt64 = LEDWatchCoordinator.defaultRetryBaseNanoseconds,
        retryJitter: @escaping (ClosedRange<UInt64>) -> UInt64 = { UInt64.random(in: $0) }
    ) {
        self.controller = controller
        self.reportResult = reportResult
        self.reportError = reportError
        self.retryBaseNanoseconds = retryBaseNanoseconds
        self.retryJitter = retryJitter
        maintainer = LEDOnMaintainer(controller: controller, reportError: reportError)
    }

    func start(initialMode: LEDMode) {
        precondition(initialMode != .automatic)
        queue.sync {
            guard !isActive, !isStopped else { return }
            desiredMode = initialMode
            isActive = true
            isHalted = false
            generation &+= 1
            resetFailures()
        }
    }

    func toggle() {
        queue.async { [weak self] in
            guard let self, self.isActive, !self.isStopped, !self.isHalted else { return }
            self.toggleOnQueue()
        }
    }

    func stopAndWait() {
        queue.sync {
            isActive = false
            isStopped = true
            generation &+= 1 // Invalidates delayed retries already on the queue.
            maintainer.stopAndWait()
        }
    }

    private func toggleOnQueue() {
        dispatchPrecondition(condition: .onQueue(queue))
        desiredMode = desiredMode == .on ? .off : .on
        generation &+= 1
        resetFailures()
        applyDesiredMode(generation: generation)
    }

    private func applyDesiredMode(generation: UInt64) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard isActive, !isHalted, generation == self.generation else { return }

        do {
            let result: LEDUpdateResult
            switch desiredMode {
            case .on:
                result = try controller.setMode(.on)
                // Start only after the first On write succeeds. Otherwise the
                // 10 ms repair loop would race this operation's backoff policy.
                maintainer.start()
            case .off:
                // Drain a possible repair before writing Off; a late repair
                // would otherwise win and reverse the user's toggle.
                maintainer.stopAndWait()
                result = try controller.setMode(.off)
            case .automatic:
                preconditionFailure("watch never maintains automatic mode")
            }

            resetFailures()
            reportResult(desiredMode, result)
        } catch {
            handleFailure(error, generation: generation)
        }
    }

    private func handleFailure(_ error: Error, generation: UInt64) {
        let signature = "\(String(reflecting: type(of: error))):\(error.localizedDescription)"
        if signature == lastFailureSignature {
            repeatedFailureCount += 1
        } else {
            lastFailureSignature = signature
            repeatedFailureCount = 1
        }

        guard repeatedFailureCount < Self.repeatedFailureLimit else {
            isHalted = true
            reportError(
                "capsled: LED toggling stopped after "
                    + "\(Self.repeatedFailureLimit) repeated failures: "
                    + error.localizedDescription
            )
            return
        }

        // A controller failure is an external-service failure. The first two
        // equal failures use exponential backoff with 0...50% random jitter;
        // the third halts simple retries so the cause can be investigated.
        let exponent = UInt64(repeatedFailureCount - 1)
        let baseDelay = retryBaseNanoseconds << exponent
        let jitter = retryJitter(0...(baseDelay / 2))
        queue.asyncAfter(deadline: .now() + .nanoseconds(Int(baseDelay + jitter))) {
            [weak self] in
            self?.applyDesiredMode(generation: generation)
        }
    }

    private func resetFailures() {
        lastFailureSignature = nil
        repeatedFailureCount = 0
    }
}
