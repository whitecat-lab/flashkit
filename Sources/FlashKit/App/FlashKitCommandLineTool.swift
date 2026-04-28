import Darwin
import Foundation

enum FlashKitCommandLineTool {
    private static let rawWriteFlag = "--flashkit-raw-write"

    static func runIfRequested(arguments: [String] = CommandLine.arguments) {
        guard arguments.contains(rawWriteFlag) else {
            return
        }

        do {
            let request = try parseRawWriteRequest(arguments: arguments)
            let bytesWritten = try copyRawBytes(
                sourcePath: request.sourcePath,
                destinationPath: request.destinationPath,
                expectedBytes: request.expectedBytes,
                progressFilePath: request.progressFilePath
            )
            writeStandardError("FlashKit raw write completed: \(bytesWritten) bytes\n")
            exit(0)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            writeStandardError("\(message)\n")
            exit(1)
        }
    }

    static func copyRawBytes(
        sourcePath: String,
        destinationPath: String,
        expectedBytes: Int64?,
        progressFilePath: String? = nil
    ) throws -> Int64 {
        let sourceFD = open(sourcePath, O_RDONLY)
        guard sourceFD >= 0 else {
            throw CommandLineRawWriteError.openFailed(path: sourcePath, operation: "read", errno: errno)
        }
        defer { close(sourceFD) }

        let destinationFD = open(destinationPath, O_WRONLY)
        guard destinationFD >= 0 else {
            throw CommandLineRawWriteError.openFailed(path: destinationPath, operation: "write", errno: errno)
        }
        defer { close(destinationFD) }

        let bufferSize = 4 * 1024 * 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        var bytesWritten: Int64 = 0
        let startTime = Date()
        var lastProgressUpdate = Date.distantPast
        while true {
            if let expectedBytes, bytesWritten >= expectedBytes {
                break
            }

            let bytesToRead: Int
            if let expectedBytes {
                bytesToRead = min(bufferSize, Int(max(expectedBytes - bytesWritten, 0)))
            } else {
                bytesToRead = bufferSize
            }
            if bytesToRead == 0 {
                break
            }

            let readCount = retryingErrno { read(sourceFD, buffer, bytesToRead) }
            if readCount < 0 {
                throw CommandLineRawWriteError.ioFailed(path: sourcePath, operation: "read", errno: errno)
            }
            if readCount == 0 {
                if let expectedBytes, bytesWritten < expectedBytes {
                    throw CommandLineRawWriteError.shortRead(expectedBytes: expectedBytes, actualBytes: bytesWritten)
                }
                break
            }

            var offset = 0
            while offset < readCount {
                let writeCount = retryingErrno {
                    write(destinationFD, buffer.advanced(by: offset), readCount - offset)
                }
                if writeCount < 0 {
                    throw CommandLineRawWriteError.ioFailed(path: destinationPath, operation: "write", errno: errno)
                }
                offset += writeCount
            }

            bytesWritten += Int64(readCount)
            let now = Date()
            if now.timeIntervalSince(lastProgressUpdate) >= 0.25 {
                try writeProgress(
                    to: progressFilePath,
                    completedBytes: bytesWritten,
                    totalBytes: expectedBytes,
                    startedAt: startTime
                )
                lastProgressUpdate = now
            }
        }

        guard fsync(destinationFD) == 0 else {
            throw CommandLineRawWriteError.ioFailed(path: destinationPath, operation: "sync", errno: errno)
        }
        try writeProgress(
            to: progressFilePath,
            completedBytes: bytesWritten,
            totalBytes: expectedBytes,
            startedAt: startTime
        )

        return bytesWritten
    }

    private struct RawWriteRequest {
        let sourcePath: String
        let destinationPath: String
        let expectedBytes: Int64?
        let progressFilePath: String?
    }

    private static func parseRawWriteRequest(arguments: [String]) throws -> RawWriteRequest {
        var sourcePath: String?
        var destinationPath: String?
        var expectedBytes: Int64?
        var progressFilePath: String?
        var index = 1

        while index < arguments.count {
            switch arguments[index] {
            case rawWriteFlag:
                index += 1
            case "--source":
                guard index + 1 < arguments.count else {
                    throw CommandLineRawWriteError.missingValue("--source")
                }
                sourcePath = arguments[index + 1]
                index += 2
            case "--destination":
                guard index + 1 < arguments.count else {
                    throw CommandLineRawWriteError.missingValue("--destination")
                }
                destinationPath = arguments[index + 1]
                index += 2
            case "--expected-bytes":
                guard index + 1 < arguments.count else {
                    throw CommandLineRawWriteError.missingValue("--expected-bytes")
                }
                guard let parsed = Int64(arguments[index + 1]), parsed >= 0 else {
                    throw CommandLineRawWriteError.invalidValue("--expected-bytes")
                }
                expectedBytes = parsed
                index += 2
            case "--progress-file":
                guard index + 1 < arguments.count else {
                    throw CommandLineRawWriteError.missingValue("--progress-file")
                }
                progressFilePath = arguments[index + 1]
                index += 2
            default:
                throw CommandLineRawWriteError.invalidValue(arguments[index])
            }
        }

        guard let sourcePath else {
            throw CommandLineRawWriteError.missingValue("--source")
        }
        guard let destinationPath else {
            throw CommandLineRawWriteError.missingValue("--destination")
        }

        return RawWriteRequest(
            sourcePath: sourcePath,
            destinationPath: destinationPath,
            expectedBytes: expectedBytes,
            progressFilePath: progressFilePath
        )
    }

    private static func writeProgress(
        to progressFilePath: String?,
        completedBytes: Int64,
        totalBytes: Int64?,
        startedAt: Date
    ) throws {
        guard let progressFilePath else {
            return
        }

        let elapsed = max(Date().timeIntervalSince(startedAt), 0.001)
        let snapshot = CommandLineRawWriteProgress(
            completedBytes: completedBytes,
            totalBytes: totalBytes,
            rateBytesPerSecond: Double(completedBytes) / elapsed
        )
        let data = try JSONEncoder().encode(snapshot)
        try data.write(to: URL(fileURLWithPath: progressFilePath), options: .atomic)
    }

    private static func retryingErrno(_ work: () -> Int) -> Int {
        while true {
            let result = work()
            if result >= 0 || errno != EINTR {
                return result
            }
        }
    }

    private static func writeStandardError(_ message: String) {
        FileHandle.standardError.write(Data(message.utf8))
    }
}

private struct CommandLineRawWriteProgress: Codable {
    let completedBytes: Int64
    let totalBytes: Int64?
    let rateBytesPerSecond: Double
}

enum CommandLineRawWriteError: LocalizedError {
    case missingValue(String)
    case invalidValue(String)
    case openFailed(path: String, operation: String, errno: Int32)
    case ioFailed(path: String, operation: String, errno: Int32)
    case shortRead(expectedBytes: Int64, actualBytes: Int64)

    var errorDescription: String? {
        switch self {
        case let .missingValue(option):
            return "Missing value for \(option)."
        case let .invalidValue(value):
            return "Invalid raw-write argument: \(value)."
        case let .openFailed(path, operation, errorNumber):
            return "FlashKit could not open \(path) for \(operation): \(posixMessage(errorNumber))."
        case let .ioFailed(path, operation, errorNumber):
            return "FlashKit could not \(operation) \(path): \(posixMessage(errorNumber))."
        case let .shortRead(expectedBytes, actualBytes):
            return "FlashKit raw write ended early after \(actualBytes) of \(expectedBytes) bytes."
        }
    }

    private func posixMessage(_ errorNumber: Int32) -> String {
        String(cString: strerror(errorNumber))
    }
}
