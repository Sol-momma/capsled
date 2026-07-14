import Foundation

/// Runs a short synchronous startup operation with the same failure policy used
/// by the asynchronous LED maintainers: exponential backoff, random jitter, and
/// no more blind retries after the third failure.
enum ExternalServiceRetry {
    private static let attemptLimit = 3
    private static let defaultBaseNanoseconds: UInt64 = 25_000_000

    static func perform<Value>(
        baseNanoseconds: UInt64 = defaultBaseNanoseconds,
        jitter: (ClosedRange<UInt64>) -> UInt64 = { UInt64.random(in: $0) },
        sleep: (UInt64) -> Void = sleepNanoseconds,
        shouldRetry: (Error) -> Bool = { _ in true },
        operation: () throws -> Value
    ) throws -> Value {
        var attempt = 0
        while true {
            do {
                return try operation()
            } catch {
                attempt += 1
                guard attempt < attemptLimit, shouldRetry(error) else {
                    throw error
                }

                let baseDelay = baseNanoseconds << UInt64(attempt - 1)
                let randomDelay = jitter(0...(baseDelay / 2))
                sleep(baseDelay + randomDelay)
            }
        }
    }

    private static func sleepNanoseconds(_ nanoseconds: UInt64) {
        // Startup retries are intentionally short and synchronous. This avoids
        // exposing a half-initialized watcher while still giving IOKit service
        // enumeration or a transient connection failure time to settle.
        Thread.sleep(forTimeInterval: Double(nanoseconds) / 1_000_000_000)
    }
}
