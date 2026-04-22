import Foundation

struct ProcessResult: Sendable {
    let standardOutput: Data
    let standardError: Data

    var standardOutputText: String {
        String(decoding: standardOutput, as: UTF8.self)
    }

    var standardErrorText: String {
        String(decoding: standardError, as: UTF8.self)
    }
}

enum ProcessRunnerError: LocalizedError {
    case nonZeroExit(command: String, code: Int32, standardError: String)

    var errorDescription: String? {
        switch self {
        case let .nonZeroExit(command, code, standardError):
            let trimmed = standardError.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return "\(command) exited with status \(code)."
            }

            return "\(command) exited with status \(code): \(trimmed)"
        }
    }
}

private final class ProcessExecutionState: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var continuation: CheckedContinuation<ProcessResult, Error>?

    func register(process: Process, continuation: CheckedContinuation<ProcessResult, Error>) {
        lock.lock()
        self.process = process
        self.continuation = continuation
        lock.unlock()
    }

    func resume(with result: Result<ProcessResult, Error>) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()

        guard let continuation else {
            return
        }

        continuation.resume(with: result)
    }

    func cancel() {
        lock.lock()
        let process = self.process
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()

        if process?.isRunning == true {
            process?.terminate()
        }

        continuation?.resume(throwing: CancellationError())
    }
}

struct ProcessRunner {
    func run(
        _ executable: String,
        arguments: [String],
        currentDirectory: URL? = nil,
        onStart: (@Sendable (Int32) async -> Void)? = nil
    ) async throws -> ProcessResult {
        try Task.checkCancellation()
        let state = ProcessExecutionState()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let process = Process()
                let standardOutput = Pipe()
                let standardError = Pipe()

                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                process.standardOutput = standardOutput
                process.standardError = standardError
                process.currentDirectoryURL = currentDirectory

                state.register(process: process, continuation: continuation)

                process.terminationHandler = { process in
                    let output = standardOutput.fileHandleForReading.readDataToEndOfFile()
                    let error = standardError.fileHandleForReading.readDataToEndOfFile()

                    if process.terminationStatus == 0 {
                        state.resume(with: .success(ProcessResult(standardOutput: output, standardError: error)))
                        return
                    }

                    let command = ([executable] + arguments).joined(separator: " ")
                    state.resume(
                        with: .failure(
                            ProcessRunnerError.nonZeroExit(
                                command: command,
                                code: process.terminationStatus,
                                standardError: String(decoding: error, as: UTF8.self)
                            )
                        )
                    )
                }

                do {
                    try process.run()
                    if let onStart {
                        Task {
                            await onStart(process.processIdentifier)
                        }
                    }
                } catch {
                    state.resume(with: .failure(error))
                }
            }
        } onCancel: {
            state.cancel()
        }
    }
}
