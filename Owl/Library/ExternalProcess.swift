import Foundation

/// Runs one of the command line tools installed alongside libmpv and hands back
/// what it wrote.
enum ExternalProcess {
    /// Runs `executable` on `queue` and returns its standard output, or `nil`
    /// when the process fails, is cancelled, or cannot be started.
    ///
    /// The queue is the caller's, because what should not pile up differs by
    /// caller: scrubbing previews replace each other and want one process at a
    /// time, while a folder of files being read is a different line entirely.
    static func run(
        executable: URL,
        arguments: [String],
        on queue: DispatchQueue
    ) async -> Data? {
        let box = ProcessBox()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
                queue.async {
                    let process = Process()
                    process.executableURL = executable
                    process.arguments = arguments
                    let output = Pipe()
                    process.standardOutput = output
                    process.standardError = FileHandle.nullDevice
                    process.standardInput = FileHandle.nullDevice

                    guard !box.isCancelled else {
                        continuation.resume(returning: nil)
                        return
                    }

                    do {
                        try process.run()
                    } catch {
                        continuation.resume(returning: nil)
                        return
                    }

                    // The process is handed over only once it is running,
                    // because terminating an unlaunched process raises. A
                    // failed adoption means the task was cancelled while the
                    // process was starting, so it is stopped here instead.
                    guard box.adopt(process) else {
                        process.terminate()
                        process.waitUntilExit()
                        continuation.resume(returning: nil)
                        return
                    }

                    // Drain the pipe before waiting so output larger than the
                    // pipe buffer cannot deadlock the process.
                    let data = (try? output.fileHandleForReading.readToEnd()) ?? Data()
                    process.waitUntilExit()
                    let status = process.terminationStatus
                    box.finish()
                    continuation.resume(returning: status == 0 ? data : nil)
                }
            }
        } onCancel: {
            box.cancel()
        }
    }
}

/// Shares a running process with whoever may cancel it, which is never the
/// queue that owns the process.
final class ProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    /// Takes ownership of an already launched process. Returns `false` when
    /// the task was cancelled while it was starting, leaving the caller to
    /// stop it.
    func adopt(_ process: Process) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { return false }
        self.process = process
        return true
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let running = process
        process = nil
        lock.unlock()
        guard let running, running.isRunning else { return }
        running.terminate()
    }

    func finish() {
        lock.lock()
        process = nil
        lock.unlock()
    }
}
