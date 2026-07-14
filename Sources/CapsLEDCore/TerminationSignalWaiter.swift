import Darwin
import Foundation

protocol TerminationWaiting: AnyObject {
    func wait() -> Int32
}

/// Converts SIGINT/SIGTERM into a wait result so watch can clean up normally.
/// SIGKILL remains intentionally unhandleable and shares `run`'s documented
/// recovery command: invoke `capsled auto` after a forced termination.
final class TerminationSignalWaiter: TerminationWaiting {
    private let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var receivedSignal: Int32?
    private var sources: [DispatchSourceSignal] = []

    init() {
        let signalNumbers = [SIGINT, SIGTERM]
        var blockedSignals = sigset_t()
        var previousMask = sigset_t()
        sigemptyset(&blockedSignals)
        signalNumbers.forEach { sigaddset(&blockedSignals, $0) }

        // Block both termination signals while all sources are armed. Without
        // this critical section, one signal can keep its default termination
        // behavior while the other source is being created, or be ignored in
        // the gap between SIG_IGN and source activation.
        let didBlock = pthread_sigmask(SIG_BLOCK, &blockedSignals, &previousMask) == 0
        defer {
            if didBlock {
                pthread_sigmask(SIG_SETMASK, &previousMask, nil)
            }
        }

        for signalNumber in signalNumbers {
            let source = DispatchSource.makeSignalSource(
                signal: signalNumber,
                queue: DispatchQueue.global(qos: .userInitiated)
            )
            source.setEventHandler { [weak self] in
                self?.record(signalNumber)
            }
            source.resume()
            sources.append(source)
        }
        signalNumbers.forEach { signal($0, SIG_IGN) }
    }

    func wait() -> Int32 {
        semaphore.wait()
        return lock.withLock { receivedSignal ?? SIGTERM }
    }

    deinit {
        sources.forEach { $0.cancel() }
        sources.removeAll()
        signal(SIGINT, SIG_DFL)
        signal(SIGTERM, SIG_DFL)
    }

    private func record(_ signalNumber: Int32) {
        let isFirst = lock.withLock {
            guard receivedSignal == nil else { return false }
            receivedSignal = signalNumber
            return true
        }
        if isFirst {
            semaphore.signal()
        }
    }
}
