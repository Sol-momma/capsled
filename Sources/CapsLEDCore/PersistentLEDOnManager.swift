import Darwin
import Foundation

enum PersistentLEDOnStartResult: Equatable {
    case started(LEDUpdateResult)
    case alreadyRunning
}

protocol PersistentLEDOnManaging {
    func start() throws -> PersistentLEDOnStartResult
    func stop() throws
}

enum PersistentLEDOnError: LocalizedError {
    case executableUnavailable
    case invalidWorkerArguments
    case invalidState
    case workerFailed(String)
    case workerDidNotBecomeReady
    case workerDidNotStop(pid: pid_t)
    case operationBusy
    case systemCall(String, code: Int32)

    var errorDescription: String? {
        switch self {
        case .executableUnavailable:
            "could not locate the capsled executable"
        case .invalidWorkerArguments:
            "invalid internal LED maintainer arguments"
        case .invalidState:
            "the LED maintainer state is invalid"
        case let .workerFailed(message):
            "the LED maintainer could not start: \(message)"
        case .workerDidNotBecomeReady:
            "the LED maintainer did not report readiness"
        case let .workerDidNotStop(pid):
            "the LED maintainer (pid \(pid)) did not stop"
        case .operationBusy:
            "another capsled ownership change is still in progress"
        case let .systemCall(name, code):
            "\(name) failed with errno \(code): \(String(cString: strerror(code)))"
        }
    }
}

/// Owns the detached process used by `capsled on`.
///
/// Retaining an IOHID client does not reserve `HIDCapsLockLED`, so persistence
/// requires a live process that can repair macOS's later Off writes. A private
/// per-user directory and an advisory lock provide two useful guarantees without
/// installing a launch agent: only one maintainer is active, and `off`, `auto`,
/// or `run` can wait until its final On repair has drained before writing.
final class PersistentLEDOnProcessManager: PersistentLEDOnManaging {
    static let workerCommand = "__capsled-maintain-on"

    private static let startupRetryBaseNanoseconds: UInt64 = 100_000_000
    private static let stopRetryBaseNanoseconds: UInt64 = 100_000_000
    // A start/stop operation can legitimately spend about one second in its own
    // three-attempt backoff. Using a wider base here lets a colliding command
    // observe that normal completion before its third and final lock check.
    private static let operationRetryBaseNanoseconds: UInt64 = 500_000_000
    private static let retryLimit = 3

    private let runtimeDirectory: URL
    private let executableURL: URL

    init(
        runtimeDirectory: URL = PersistentLEDOnProcessManager.defaultRuntimeDirectory(),
        executableURL: URL? = Bundle.main.executableURL
    ) throws {
        guard let executableURL else {
            throw PersistentLEDOnError.executableUnavailable
        }
        self.runtimeDirectory = runtimeDirectory
        self.executableURL = executableURL
    }

    func start() throws -> PersistentLEDOnStartResult {
        try prepareRuntimeDirectory()
        return try withOperationLock {
            try startWhileLocked()
        }
    }

    private func startWhileLocked() throws -> PersistentLEDOnStartResult {
        // The fast path avoids creating another process for repeated `on`
        // commands. The worker also takes this ownership lock, independently of
        // the operation lock, so a direct hidden-worker launch cannot duplicate it.
        if try isWorkerRunning() {
            return .alreadyRunning
        }

        let readinessURL = runtimeDirectory
            .appendingPathComponent("ready-\(UUID().uuidString)", isDirectory: false)
        let acknowledgementURL = readinessURL.appendingPathExtension("ack")

        let process = Process()
        process.executableURL = executableURL
        process.arguments = [
            Self.workerCommand,
            lockURL.path,
            readinessURL.path,
            acknowledgementURL.path,
        ]

        // A persistent `on` must not retain the invoking terminal's pipes or
        // receive its hangup. Startup errors are returned through the readiness
        // file, which lets all three standard streams be detached safely.
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()

        for attempt in 0..<Self.retryLimit {
            if let status = try readWorkerStatus(at: readinessURL) {
                return try consume(
                    status,
                    readinessURL: readinessURL,
                    acknowledgementURL: acknowledgementURL
                )
            }
            if !process.isRunning {
                // Atomic rename can publish the terminal status between the
                // first read and observing process exit. Read once more before
                // reducing a useful worker error to a generic readiness failure.
                if let status = try readWorkerStatus(at: readinessURL) {
                    return try consume(
                        status,
                        readinessURL: readinessURL,
                        acknowledgementURL: acknowledgementURL
                    )
                }
                removeStartupFiles(readinessURL, acknowledgementURL)
                throw PersistentLEDOnError.workerDidNotBecomeReady
            }
            sleepWithBackoff(
                baseNanoseconds: Self.startupRetryBaseNanoseconds,
                attempt: attempt
            )
        }

        if let status = try readWorkerStatus(at: readinessURL) {
            return try consume(
                status,
                readinessURL: readinessURL,
                acknowledgementURL: acknowledgementURL
            )
        }

        // Three missed readiness checks indicate a startup fault rather than a
        // transient delay. Stop the unconfirmed process instead of leaving an
        // invisible maintainer whose ownership the caller cannot verify.
        if process.isRunning {
            if let status = try readWorkerStatus(at: readinessURL) {
                return try consume(
                    status,
                    readinessURL: readinessURL,
                    acknowledgementURL: acknowledgementURL
                )
            }
            process.terminate()
            for attempt in 0..<Self.retryLimit {
                if !process.isRunning { break }
                sleepWithBackoff(
                    baseNanoseconds: Self.stopRetryBaseNanoseconds,
                    attempt: attempt
                )
            }
            if process.isRunning {
                // SIGKILL would skip HID cleanup. Report the residual PID so the
                // caller can investigate instead of changing the documented
                // no-forced-termination policy only on the startup path.
                throw PersistentLEDOnError.workerDidNotStop(
                    pid: process.processIdentifier
                )
            }
        }
        removeStartupFiles(readinessURL, acknowledgementURL)
        throw PersistentLEDOnError.workerDidNotBecomeReady
    }

    func stop() throws {
        try prepareRuntimeDirectory()
        try withOperationLock {
            try stopWhileLocked()
        }
    }

    private func stopWhileLocked() throws {
        let descriptor = try openLockFile()
        defer { close(descriptor) }

        if try acquireLockIfAvailable(descriptor) {
            clearLockFile(descriptor)
            flock(descriptor, LOCK_UN)
            return
        }

        let pid = try readWorkerPID(descriptor)
        if kill(pid, SIGTERM) == -1, errno != ESRCH {
            throw PersistentLEDOnError.systemCall("kill", code: errno)
        }

        for attempt in 0..<Self.retryLimit {
            sleepWithBackoff(
                baseNanoseconds: Self.stopRetryBaseNanoseconds,
                attempt: attempt
            )
            if try acquireLockIfAvailable(descriptor) {
                clearLockFile(descriptor)
                flock(descriptor, LOCK_UN)
                return
            }
        }

        // Do not escalate to SIGKILL: the worker may be inside an HID call, and
        // killing it would skip the ordering guarantee that protects the final
        // off/auto write. A persistent failure is surfaced for investigation.
        throw PersistentLEDOnError.workerDidNotStop(pid: pid)
    }

    static func parseWorkerRequest(_ arguments: [String]) throws -> (
        lockURL: URL,
        readinessURL: URL,
        acknowledgementURL: URL
    ) {
        guard arguments.count == 4, arguments[0] == workerCommand else {
            throw PersistentLEDOnError.invalidWorkerArguments
        }
        return (
            URL(fileURLWithPath: arguments[1]),
            URL(fileURLWithPath: arguments[2]),
            URL(fileURLWithPath: arguments[3])
        )
    }

    private var lockURL: URL {
        runtimeDirectory.appendingPathComponent("maintainer.lock", isDirectory: false)
    }

    private var operationLockURL: URL {
        runtimeDirectory.appendingPathComponent("operation.lock", isDirectory: false)
    }

    private static func defaultRuntimeDirectory() -> URL {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return applicationSupport.appendingPathComponent("capsled", isDirectory: true)
    }

    private func prepareRuntimeDirectory() throws {
        try FileManager.default.createDirectory(
            at: runtimeDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        let values = try runtimeDirectory.resourceValues(forKeys: [
            .isDirectoryKey,
            .isSymbolicLinkKey,
        ])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw PersistentLEDOnError.invalidState
        }

        // Application Support is stable across temporary-file cleanup. Explicit
        // 0700 permissions also keep the PID/lock protocol private on machines
        // whose parent Library permissions are more permissive.
        if chmod(runtimeDirectory.path, S_IRWXU) == -1 {
            throw PersistentLEDOnError.systemCall("chmod", code: errno)
        }
    }

    private func isWorkerRunning() throws -> Bool {
        let descriptor = try openLockFile()
        defer { close(descriptor) }

        if try acquireLockIfAvailable(descriptor) {
            flock(descriptor, LOCK_UN)
            return false
        }
        return true
    }

    private func openLockFile() throws -> Int32 {
        try openLockFile(at: lockURL)
    }

    private func openLockFile(at url: URL) throws -> Int32 {
        let descriptor = open(url.path, O_RDWR | O_CREAT, S_IRUSR | S_IWUSR)
        guard descriptor != -1 else {
            throw PersistentLEDOnError.systemCall("open", code: errno)
        }
        return descriptor
    }

    private func withOperationLock<T>(_ operation: () throws -> T) throws -> T {
        let descriptor = try openLockFile(at: operationLockURL)
        defer { close(descriptor) }

        for attempt in 0..<Self.retryLimit {
            if try acquireLockIfAvailable(descriptor) {
                defer { flock(descriptor, LOCK_UN) }
                return try operation()
            }

            guard attempt + 1 < Self.retryLimit else { break }
            sleepWithBackoff(
                baseNanoseconds: Self.operationRetryBaseNanoseconds,
                attempt: attempt
            )
        }

        // Three observations of the same ownership transition mean the other
        // command is no longer a short collision. Surface it instead of stacking
        // more state changes behind an operation whose progress is unknown.
        throw PersistentLEDOnError.operationBusy
    }

    private func acquireLockIfAvailable(_ descriptor: Int32) throws -> Bool {
        if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
            return true
        }
        if errno == EWOULDBLOCK || errno == EAGAIN {
            return false
        }
        throw PersistentLEDOnError.systemCall("flock", code: errno)
    }

    private func readWorkerPID(_ descriptor: Int32) throws -> pid_t {
        guard lseek(descriptor, 0, SEEK_SET) != -1 else {
            throw PersistentLEDOnError.systemCall("lseek", code: errno)
        }

        var buffer = [UInt8](repeating: 0, count: 64)
        let count = buffer.withUnsafeMutableBytes { rawBuffer in
            read(descriptor, rawBuffer.baseAddress, rawBuffer.count)
        }
        guard count > 0 else {
            if count == -1 {
                throw PersistentLEDOnError.systemCall("read", code: errno)
            }
            throw PersistentLEDOnError.invalidState
        }

        let text = String(decoding: buffer.prefix(count), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let pid = pid_t(text), pid > 1 else {
            throw PersistentLEDOnError.invalidState
        }
        return pid
    }

    private func readWorkerStatus(at url: URL) throws -> PersistentLEDOnWorkerStatus? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(PersistentLEDOnWorkerStatus.self, from: data)
    }

    private func interpret(
        _ status: PersistentLEDOnWorkerStatus
    ) throws -> PersistentLEDOnStartResult {
        switch status.kind {
        case .ready:
            guard let matchedKeyboards = status.matchedKeyboards,
                  let targetedKeyboards = status.targetedKeyboards,
                  let successfulWrites = status.successfulWrites else {
                throw PersistentLEDOnError.invalidState
            }
            return .started(
                LEDUpdateResult(
                    matchedKeyboards: matchedKeyboards,
                    targetedKeyboards: targetedKeyboards,
                    successfulWrites: successfulWrites
                )
            )
        case .alreadyRunning:
            return .alreadyRunning
        case .failed:
            throw PersistentLEDOnError.workerFailed(status.message ?? "unknown error")
        }
    }

    private func consume(
        _ status: PersistentLEDOnWorkerStatus,
        readinessURL: URL,
        acknowledgementURL: URL
    ) throws -> PersistentLEDOnStartResult {
        defer { try? FileManager.default.removeItem(at: readinessURL) }
        let result = try interpret(status)

        if case .started = result {
            // Publishing readiness alone is not enough: the invoking parent may
            // be killed before it observes that status. This ACK transfers durable
            // ownership to the worker; without it, the worker restores Auto and
            // exits instead of becoming an unintended orphan.
            try Data("ack".utf8).write(to: acknowledgementURL, options: .atomic)
        }
        return result
    }

    private func removeStartupFiles(_ urls: URL...) {
        urls.forEach { try? FileManager.default.removeItem(at: $0) }
    }

    private func sleepWithBackoff(baseNanoseconds: UInt64, attempt: Int) {
        let delay = baseNanoseconds << UInt64(attempt)
        let jitter = UInt64.random(in: 0...(delay / 2))
        let total = delay + jitter
        Thread.sleep(forTimeInterval: Double(total) / 1_000_000_000)
    }

    private func clearLockFile(_ descriptor: Int32) {
        _ = ftruncate(descriptor, 0)
    }
}

private struct PersistentLEDOnWorkerStatus: Codable {
    enum Kind: String, Codable {
        case ready
        case alreadyRunning
        case failed
    }

    let kind: Kind
    let matchedKeyboards: Int?
    let targetedKeyboards: Int?
    let successfulWrites: Int?
    let message: String?

    static func ready(_ result: LEDUpdateResult) -> Self {
        Self(
            kind: .ready,
            matchedKeyboards: result.matchedKeyboards,
            targetedKeyboards: result.targetedKeyboards,
            successfulWrites: result.successfulWrites,
            message: nil
        )
    }

    static let alreadyRunning = Self(
        kind: .alreadyRunning,
        matchedKeyboards: nil,
        targetedKeyboards: nil,
        successfulWrites: nil,
        message: nil
    )

    static func failed(_ error: Error) -> Self {
        Self(
            kind: .failed,
            matchedKeyboards: nil,
            targetedKeyboards: nil,
            successfulWrites: nil,
            message: error.localizedDescription
        )
    }
}

final class PersistentLEDOnWorker {
    private static let acknowledgementRetryBaseNanoseconds: UInt64 = 500_000_000
    private static let acknowledgementRetryLimit = 3

    private let lockURL: URL
    private let readinessURL: URL
    private let acknowledgementURL: URL
    private let controller: CapsLockLEDControlling

    init(
        lockURL: URL,
        readinessURL: URL,
        acknowledgementURL: URL,
        controller: CapsLockLEDControlling
    ) {
        self.lockURL = lockURL
        self.readinessURL = readinessURL
        self.acknowledgementURL = acknowledgementURL
        self.controller = controller
    }

    func run() -> Int32 {
        var descriptor: Int32 = -1
        var ownsLock = false

        defer {
            if descriptor != -1 {
                if ownsLock {
                    _ = ftruncate(descriptor, 0)
                    flock(descriptor, LOCK_UN)
                }
                close(descriptor)
            }
        }

        do {
            // Foundation Process launches this child as a process-group leader,
            // which makes setsid() fail with EPERM. The worker is already outside
            // the caller's foreground process group and has no terminal streams;
            // ignoring SIGHUP completes the detachment needed for terminal exit.
            signal(SIGHUP, SIG_IGN)

            descriptor = open(lockURL.path, O_RDWR | O_CREAT, S_IRUSR | S_IWUSR)
            guard descriptor != -1 else {
                throw PersistentLEDOnError.systemCall("open", code: errno)
            }

            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
                if errno == EWOULDBLOCK || errno == EAGAIN {
                    try writeStatus(.alreadyRunning)
                    return 0
                }
                throw PersistentLEDOnError.systemCall("flock", code: errno)
            }
            ownsLock = true
            try writePID(descriptor)

            let termination = DispatchSemaphore(value: 0)
            let signals = terminationSignalSources(semaphore: termination)
            defer { signals.forEach { $0.cancel() } }
            let ownershipMonitor = makeOwnershipMonitor(
                descriptor: descriptor,
                termination: termination
            )
            defer { ownershipMonitor.cancel() }

            let result = try controller.setMode(.on)
            let maintainer = LEDOnMaintainer(controller: controller) { _ in
                // Maintenance already stops after three equal failures. Letting
                // the worker exit releases the ownership lock so a later `on`
                // can recover instead of leaving a live but ineffective daemon.
                termination.signal()
            }
            maintainer.start()
            defer {
                maintainer.stopAndWait()
                // A direct SIGTERM should not strand the LED override. Commands
                // such as `off` write their requested mode only after this worker
                // releases its lock, so this Auto write cannot win the final race.
                _ = try? controller.setMode(.automatic)
            }

            try writeStatus(.ready(result))
            guard waitForParentAcknowledgement(termination: termination) else {
                // The parent died or stopped making progress before accepting
                // ownership. Cleanup defers restore Auto and release the lock.
                try? FileManager.default.removeItem(at: readinessURL)
                return 69
            }
            termination.wait()
            return 0
        } catch {
            try? writeStatus(.failed(error))
            return 69
        }
    }

    private func terminationSignalSources(
        semaphore: DispatchSemaphore
    ) -> [DispatchSourceSignal] {
        [SIGINT, SIGTERM].map { signalNumber in
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(
                signal: signalNumber,
                queue: DispatchQueue.global(qos: .userInitiated)
            )
            source.setEventHandler {
                semaphore.signal()
            }
            source.resume()
            return source
        }
    }

    private func makeOwnershipMonitor(
        descriptor: Int32,
        termination: DispatchSemaphore
    ) -> DispatchSourceTimer {
        let source = DispatchSource.makeTimerSource(
            queue: DispatchQueue.global(qos: .utility)
        )
        source.schedule(
            deadline: .now() + .seconds(1),
            repeating: .seconds(1),
            leeway: .milliseconds(100)
        )
        source.setEventHandler { [lockURL] in
            var descriptorInfo = stat()
            var pathInfo = stat()
            let descriptorIsValid = fstat(descriptor, &descriptorInfo) == 0
            let pathIsValid = lstat(lockURL.path, &pathInfo) == 0

            guard descriptorIsValid,
                  pathIsValid,
                  descriptorInfo.st_dev == pathInfo.st_dev,
                  descriptorInfo.st_ino == pathInfo.st_ino else {
                // A deleted/replaced state file would let a later command lock a
                // new inode and falsely conclude that no worker owns On. Exit and
                // restore Auto as soon as that ownership identity is lost.
                termination.signal()
                return
            }
        }
        source.resume()
        return source
    }

    private func writePID(_ descriptor: Int32) throws {
        guard ftruncate(descriptor, 0) == 0,
              lseek(descriptor, 0, SEEK_SET) != -1 else {
            throw PersistentLEDOnError.systemCall("prepare lock file", code: errno)
        }

        let data = Data("\(getpid())\n".utf8)
        let written = data.withUnsafeBytes { rawBuffer in
            write(descriptor, rawBuffer.baseAddress, rawBuffer.count)
        }
        guard written == data.count else {
            throw PersistentLEDOnError.systemCall("write", code: errno)
        }
        _ = fsync(descriptor)
    }

    private func writeStatus(_ status: PersistentLEDOnWorkerStatus) throws {
        let data = try JSONEncoder().encode(status)
        try data.write(to: readinessURL, options: .atomic)
    }

    private func waitForParentAcknowledgement(
        termination: DispatchSemaphore
    ) -> Bool {
        for attempt in 0..<Self.acknowledgementRetryLimit {
            if FileManager.default.fileExists(atPath: acknowledgementURL.path) {
                try? FileManager.default.removeItem(at: acknowledgementURL)
                return true
            }

            guard attempt + 1 < Self.acknowledgementRetryLimit else { break }
            let delay = Self.acknowledgementRetryBaseNanoseconds << UInt64(attempt)
            let jitter = UInt64.random(in: 0...(delay / 2))
            if termination.wait(timeout: .now() + .nanoseconds(Int(delay + jitter)))
                == .success {
                return false
            }
        }
        return false
    }
}
