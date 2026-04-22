import FlashKitHelperProtocol
import Foundation

struct AppleScriptPrivilegedClient: PrivilegedOperationClient {
    private let privilegeService = AppleScriptPrivilegeService()
    private let diskService = DiskService()

    func runSubprocess(
        executable: String,
        arguments: [String],
        currentDirectory: URL?,
        progressParser: PrivilegedSubprocessProgressParser,
        expectedTotalBytes: Int64?,
        phase: String,
        message: String,
        eventHandler: PrivilegedWorkerEventHandler?
    ) async throws -> PrivilegedOperationResult {
        let command = shellCommand(
            executable: executable,
            arguments: arguments,
            currentDirectory: currentDirectory
        )
        return try await performFallbackCommand(
            command,
            phase: phase,
            message: message,
            bytesTransferred: expectedTotalBytes,
            workerCommand: [executable] + arguments,
            eventHandler: eventHandler
        )
    }

    func writeRaw(
        sourceFilePath: String?,
        streamExecutablePath: String?,
        streamArguments: [String],
        destinationDeviceNode: String,
        expectedBytes: Int64?,
        phase: String,
        message: String,
        targetExpectation: PrivilegedTargetExpectation?,
        eventHandler: PrivilegedWorkerEventHandler?
    ) async throws -> PrivilegedOperationResult {
        try await validate(targetExpectation)

        let command: String
        let workerCommand: [String]
        if let sourceFilePath {
            command = "exec /bin/dd if=\(sourceFilePath.shellQuoted) of=\(destinationDeviceNode.shellQuoted) bs=4m status=none conv=fsync"
            workerCommand = ["/bin/dd", "if=\(sourceFilePath)", "of=\(destinationDeviceNode)", "bs=4m", "status=none", "conv=fsync"]
        } else if let streamExecutablePath {
            let streamCommand = ([streamExecutablePath] + streamArguments).map(\.shellQuoted).joined(separator: " ")
            let pipeline = "set -o pipefail; \(streamCommand) | /bin/dd of=\(destinationDeviceNode.shellQuoted) bs=4m status=none conv=fsync"
            command = "exec /bin/bash -lc \(pipeline.shellQuoted)"
            workerCommand = ["/bin/bash", "-lc", pipeline]
        } else {
            throw PrivilegedHelperClientError.invalidResponse
        }

        return try await performFallbackCommand(
            command,
            phase: phase,
            message: message,
            bytesTransferred: expectedBytes,
            workerCommand: workerCommand,
            eventHandler: eventHandler
        )
    }

    func captureRaw(
        sourceDeviceNode: String,
        destinationFilePath: String,
        expectedBytes: Int64,
        phase: String,
        message: String,
        targetExpectation: PrivilegedTargetExpectation?,
        eventHandler: PrivilegedWorkerEventHandler?
    ) async throws -> PrivilegedOperationResult {
        try await validate(targetExpectation)

        let command = "exec /bin/dd if=\(sourceDeviceNode.shellQuoted) of=\(destinationFilePath.shellQuoted) bs=4m status=none"
        let workerCommand = ["/bin/dd", "if=\(sourceDeviceNode)", "of=\(destinationFilePath)", "bs=4m", "status=none"]

        return try await performFallbackCommand(
            command,
            phase: phase,
            message: message,
            bytesTransferred: expectedBytes,
            workerCommand: workerCommand,
            eventHandler: eventHandler
        )
    }

    private func performFallbackCommand(
        _ shellCommand: String,
        phase: String,
        message: String,
        bytesTransferred: Int64?,
        workerCommand: [String],
        eventHandler: PrivilegedWorkerEventHandler?
    ) async throws -> PrivilegedOperationResult {
        if let eventHandler {
            await eventHandler(
                PrivilegedWorkerEvent(
                    operationID: UUID().uuidString,
                    kind: .message,
                    phase: phase,
                    helperPID: 0,
                    message: "Using the macOS administrator password prompt because the privileged helper is unavailable."
                )
            )
        }

        let result = try await privilegeService.run(shellCommand: shellCommand) { processID in
            guard let eventHandler else {
                return
            }

            await eventHandler(
                PrivilegedWorkerEvent(
                    operationID: UUID().uuidString,
                    kind: .childStarted,
                    phase: phase,
                    helperPID: 0,
                    childPID: processID,
                    command: workerCommand,
                    message: message
                )
            )
        }

        return PrivilegedOperationResult(
            helperProtocolVersion: PrivilegedHelperConstants.protocolVersion,
            helperPID: 0,
            childPID: nil,
            bytesTransferred: bytesTransferred,
            standardOutput: result.standardOutputText,
            standardError: result.standardErrorText
        )
    }

    private func shellCommand(
        executable: String,
        arguments: [String],
        currentDirectory: URL?
    ) -> String {
        let command = ([executable] + arguments).map(\.shellQuoted).joined(separator: " ")
        if let currentDirectory {
            return "cd \(currentDirectory.path.shellQuoted) && exec \(command)"
        }
        return "exec \(command)"
    }

    private func validate(_ targetExpectation: PrivilegedTargetExpectation?) async throws {
        guard let targetExpectation else {
            return
        }

        let info = try await diskService.diskInfo(for: targetExpectation.expectedDeviceNode)
        let currentDeviceNode = info["DeviceNode"] as? String ?? targetExpectation.expectedDeviceNode
        guard currentDeviceNode == targetExpectation.expectedDeviceNode else {
            throw BackendWritePipelineError.targetRevalidationFailure(
                "The selected target changed from \(targetExpectation.expectedDeviceNode) to \(currentDeviceNode) before the privileged write began."
            )
        }

        if targetExpectation.expectedWholeDisk {
            guard info["WholeDisk"] as? Bool ?? false else {
                throw BackendWritePipelineError.targetRevalidationFailure(
                    "The selected target is no longer available as a whole removable disk."
                )
            }
        }

        if let expectedSizeBytes = targetExpectation.expectedSizeBytes {
            let currentSize = PropertyListLoader.integer64(info["TotalSize"]) ?? PropertyListLoader.integer64(info["Size"]) ?? 0
            guard currentSize == expectedSizeBytes else {
                throw BackendWritePipelineError.targetRevalidationFailure(
                    "The selected target changed size before the privileged write began."
                )
            }
        }

        if targetExpectation.requireWritable {
            guard info["WritableMedia"] as? Bool ?? false else {
                throw BackendWritePipelineError.targetRevalidationFailure(
                    "The selected target is no longer writable."
                )
            }
        }

        if targetExpectation.requireRemovable {
            let isInternal = info["Internal"] as? Bool ?? false
            let isRemovable = info["Removable"] as? Bool ?? (info["RemovableMedia"] as? Bool ?? false)
            if isInternal || !isRemovable {
                if !(targetExpectation.allowUnsafeTargetsWithExpertOverride && targetExpectation.expertOverrideEnabled) {
                    throw BackendWritePipelineError.targetRevalidationFailure(
                        "The selected target no longer looks like the same removable USB device."
                    )
                }
            }
        }

        if targetExpectation.forceUnmountWholeDisk {
            _ = try await privilegeService.run(
                shellCommand: "exec /usr/sbin/diskutil unmountDisk force \(targetExpectation.expectedDeviceNode.shellQuoted)"
            )
        }
    }
}
