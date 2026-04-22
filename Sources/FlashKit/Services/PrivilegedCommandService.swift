import FlashKitHelperProtocol
import Foundation

struct PrivilegedCommandService {
    private let helperClient: any PrivilegedOperationClient
    private let fallbackClient: any PrivilegedOperationClient

    init(client: any PrivilegedOperationClient) {
        self.init(helperClient: client, fallbackClient: client)
    }

    init(
        helperClient: any PrivilegedOperationClient = PrivilegedHelperClient(),
        fallbackClient: any PrivilegedOperationClient = AppleScriptPrivilegedClient()
    ) {
        self.helperClient = helperClient
        self.fallbackClient = fallbackClient
    }

    func run(
        _ executable: String,
        arguments: [String],
        currentDirectory: URL? = nil,
        progressParser: PrivilegedSubprocessProgressParser = .none,
        expectedTotalBytes: Int64? = nil,
        phase: String = "Privileged work",
        message: String = "Running a privileged helper command.",
        eventHandler: PrivilegedWorkerEventHandler? = nil
    ) async throws -> PrivilegedOperationResult {
        do {
            return try await helperClient.runSubprocess(
                executable: executable,
                arguments: arguments,
                currentDirectory: currentDirectory,
                progressParser: progressParser,
                expectedTotalBytes: expectedTotalBytes,
                phase: phase,
                message: message,
                eventHandler: eventHandler
            )
        } catch let error as PrivilegedHelperClientError where error.shouldFallbackToPasswordPrompt {
            return try await fallbackClient.runSubprocess(
                executable: executable,
                arguments: arguments,
                currentDirectory: currentDirectory,
                progressParser: progressParser,
                expectedTotalBytes: expectedTotalBytes,
                phase: phase,
                message: message,
                eventHandler: eventHandler
            )
        }
    }

    func writeRaw(
        input: RawWriteInput,
        to rawDeviceNode: String,
        expectedBytes: Int64?,
        phase: String,
        message: String,
        targetExpectation: PrivilegedTargetExpectation?,
        eventHandler: PrivilegedWorkerEventHandler? = nil
    ) async throws -> PrivilegedOperationResult {
        switch input {
        case let .file(url):
            do {
                return try await helperClient.writeRaw(
                    sourceFilePath: url.path(),
                    streamExecutablePath: nil,
                    streamArguments: [],
                    destinationDeviceNode: rawDeviceNode,
                    expectedBytes: expectedBytes,
                    phase: phase,
                    message: message,
                    targetExpectation: targetExpectation,
                    eventHandler: eventHandler
                )
            } catch let error as PrivilegedHelperClientError where error.shouldFallbackToPasswordPrompt {
                return try await fallbackClient.writeRaw(
                    sourceFilePath: url.path(),
                    streamExecutablePath: nil,
                    streamArguments: [],
                    destinationDeviceNode: rawDeviceNode,
                    expectedBytes: expectedBytes,
                    phase: phase,
                    message: message,
                    targetExpectation: targetExpectation,
                    eventHandler: eventHandler
                )
            }
        case let .streamed(command):
            do {
                return try await helperClient.writeRaw(
                    sourceFilePath: nil,
                    streamExecutablePath: command.executable,
                    streamArguments: command.arguments,
                    destinationDeviceNode: rawDeviceNode,
                    expectedBytes: command.logicalSizeHint ?? expectedBytes,
                    phase: phase,
                    message: message,
                    targetExpectation: targetExpectation,
                    eventHandler: eventHandler
                )
            } catch let error as PrivilegedHelperClientError where error.shouldFallbackToPasswordPrompt {
                return try await fallbackClient.writeRaw(
                    sourceFilePath: nil,
                    streamExecutablePath: command.executable,
                    streamArguments: command.arguments,
                    destinationDeviceNode: rawDeviceNode,
                    expectedBytes: command.logicalSizeHint ?? expectedBytes,
                    phase: phase,
                    message: message,
                    targetExpectation: targetExpectation,
                    eventHandler: eventHandler
                )
            }
        }
    }

    func captureRaw(
        from rawDeviceNode: String,
        to destinationURL: URL,
        expectedBytes: Int64,
        phase: String,
        message: String,
        targetExpectation: PrivilegedTargetExpectation?,
        eventHandler: PrivilegedWorkerEventHandler? = nil
    ) async throws -> PrivilegedOperationResult {
        do {
            return try await helperClient.captureRaw(
                sourceDeviceNode: rawDeviceNode,
                destinationFilePath: destinationURL.path(),
                expectedBytes: expectedBytes,
                phase: phase,
                message: message,
                targetExpectation: targetExpectation,
                eventHandler: eventHandler
            )
        } catch let error as PrivilegedHelperClientError where error.shouldFallbackToPasswordPrompt {
            return try await fallbackClient.captureRaw(
                sourceDeviceNode: rawDeviceNode,
                destinationFilePath: destinationURL.path(),
                expectedBytes: expectedBytes,
                phase: phase,
                message: message,
                targetExpectation: targetExpectation,
                eventHandler: eventHandler
            )
        }
    }
}
