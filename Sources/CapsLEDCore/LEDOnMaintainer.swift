import Foundation

/// Keeps the physical indicator on while `capsled run` owns it.
///
/// `HIDCapsLockLED` is shared with macOS and has last-writer-wins semantics.
/// HIServices writes Off when it processes a modifier transition, even when the
/// physical Caps Lock key has already been remapped to Control. There is no
/// public service-level change notification, so this class polls the effective
/// LED state and writes only after it observes Off.
final class LEDOnMaintainer {
    // Ten milliseconds keeps the visible dark interval below a typical display
    // frame. The poll normally performs a property read only; HID writes happen
    // only when another process has replaced our On value.
    private static let pollInterval = DispatchTimeInterval.milliseconds(10)
    private static let pollLeeway = DispatchTimeInterval.milliseconds(2)

    // A failed HID call is an external-service failure, so do not retry every
    // 10 ms. The first two equal failures back off with 0...50% random jitter;
    // the third stops maintenance and reports the condition for investigation.
    private static let retryBaseNanoseconds: UInt64 = 25_000_000
    private static let repeatedFailureLimit = 3

    private let controller: CapsLockLEDControlling
    private let reportError: (String) -> Void
    private let queue = DispatchQueue(label: "capsled.led-maintainer")

    private var timer: DispatchSourceTimer?
    private var isActive = false
    private var isHalted = false
    private var nextAttemptNanoseconds: UInt64 = 0
    private var lastFailureSignature: String?
    private var repeatedFailureCount = 0

    init(
        controller: CapsLockLEDControlling,
        reportError: @escaping (String) -> Void
    ) {
        self.controller = controller
        self.reportError = reportError
    }

    func start() {
        queue.sync {
            guard timer == nil else { return }

            isActive = true
            isHalted = false
            nextAttemptNanoseconds = 0
            resetFailures()

            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(
                deadline: .now() + Self.pollInterval,
                repeating: Self.pollInterval,
                leeway: Self.pollLeeway
            )
            source.setEventHandler { [weak self] in
                self?.pollAndRepairIfNeeded()
            }
            timer = source
            source.resume()
        }
    }

    func stopAndWait() {
        // This synchronous hop waits for an in-flight repair to finish. Auto
        // must be written only after this returns; otherwise a late On repair
        // could win the race and leave the LED lit after the child has exited.
        queue.sync {
            isActive = false
            timer?.setEventHandler {}
            timer?.cancel()
            timer = nil
        }
    }

    private func pollAndRepairIfNeeded() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard isActive, !isHalted else { return }

        let now = DispatchTime.now().uptimeNanoseconds
        guard now >= nextAttemptNanoseconds else { return }

        do {
            if try !controller.isLEDOn() {
                _ = try controller.setMode(.on)
            }
            nextAttemptNanoseconds = 0
            resetFailures()
        } catch {
            handleFailure(error, now: now)
        }
    }

    private func handleFailure(_ error: Error, now: UInt64) {
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
                "capsled: LED maintenance stopped after "
                    + "\(Self.repeatedFailureLimit) repeated failures: "
                    + error.localizedDescription
            )
            return
        }

        let exponent = UInt64(repeatedFailureCount - 1)
        let baseDelay = Self.retryBaseNanoseconds << exponent
        let jitter = UInt64.random(in: 0...(baseDelay / 2))
        nextAttemptNanoseconds = now + baseDelay + jitter
    }

    private func resetFailures() {
        lastFailureSignature = nil
        repeatedFailureCount = 0
    }
}
