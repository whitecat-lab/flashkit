import FlashKitHelperProtocol
import Darwin
import Foundation

private final class OperationController: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    func register(process: Process) {
        lock.lock()
        self.process = process
        lock.unlock()
    }

    func unregisterProcess() {
        lock.lock()
        process = nil
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let process = self.process
        lock.unlock()

        process?.terminate()
    }

    var isCancelled: Bool {
        lock.lock()
        let value = cancelled
        lock.unlock()
        return value
    }
}

private enum HelperError: LocalizedError {
    case protocolMismatch
    case malformedRequest
    case targetMismatch(String)
    case failed(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .protocolMismatch:
            return "The privileged helper protocol version does not match this build of FlashKit."
        case .malformedRequest:
            return "The privileged helper received a malformed request."
        case let .targetMismatch(message):
            return message
        case let .failed(message):
            return message
        case .cancelled:
            return "The privileged helper operation was cancelled."
        }
    }
}

private enum ProgressParser {
    case none
    case ntfsPopulate(expectedTotalBytes: Int64?)
}

private struct SubprocessOutcome {
    let childPID: Int32?
    let standardOutput: String
    let standardError: String
}

private final class ReplyBox: @unchecked Sendable {
    let reply: (Data?, String?) -> Void

    init(_ reply: @escaping (Data?, String?) -> Void) {
        self.reply = reply
    }
}

private final class PrivilegedHelperService: NSObject, FlashKitPrivilegedHelperXPC, @unchecked Sendable {
    private let connection: NSXPCConnection
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let operationsLock = NSLock()
    private var operations: [String: OperationController] = [:]

    init(connection: NSXPCConnection) {
        self.connection = connection
    }

    func performRequest(_ requestData: Data, withReply reply: @escaping (Data?, String?) -> Void) {
        let replyBox = ReplyBox(reply)
        let request: PrivilegedHelperRequest
        do {
            request = try decoder.decode(PrivilegedHelperRequest.self, from: requestData)
        } catch {
            replyBox.reply(nil, HelperError.malformedRequest.localizedDescription)
            return
        }

        guard request.protocolVersion == PrivilegedHelperConstants.protocolVersion else {
            replyBox.reply(nil, HelperError.protocolMismatch.localizedDescription)
            return
        }

        let controller = OperationController()
        register(controller, for: request.operationID)

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else {
                replyBox.reply(nil, HelperError.failed("The privileged helper is no longer available.").localizedDescription)
                return
            }

            defer { self.unregisterController(for: request.operationID) }

            do {
                try await self.emitEvent(
                    PrivilegedWorkerEvent(
                        operationID: request.operationID,
                        kind: .helperStarted,
                        phase: self.phase(for: request),
                        helperPID: getpid(),
                        message: self.message(for: request)
                    )
                )

                let response = try await self.execute(request, controller: controller)
                let responseData = try self.encoder.encode(response)
                replyBox.reply(responseData, nil)
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                try? await self.emitEvent(
                    PrivilegedWorkerEvent(
                        operationID: request.operationID,
                        kind: .failed,
                        phase: self.phase(for: request),
                        helperPID: getpid(),
                        failureReason: message
                    )
                )
                replyBox.reply(nil, message)
            }
        }
    }

    func cancelOperation(_ operationID: String, withReply reply: @escaping (String?) -> Void) {
        operationsLock.lock()
        let controller = operations[operationID]
        operationsLock.unlock()

        controller?.cancel()
        reply(nil)
    }

    private func execute(_ request: PrivilegedHelperRequest, controller: OperationController) async throws -> PrivilegedHelperResponse {
        switch request.kind {
        case .subprocess:
            guard let subprocess = request.subprocess else {
                throw HelperError.malformedRequest
            }
            let outcome = try await runSubprocess(subprocess, operationID: request.operationID, controller: controller)
            try await emitEvent(
                PrivilegedWorkerEvent(
                    operationID: request.operationID,
                    kind: .finished,
                    phase: subprocess.phase,
                    helperPID: getpid(),
                    childPID: outcome.childPID
                )
            )
            return PrivilegedHelperResponse(
                helperPID: getpid(),
                childPID: outcome.childPID,
                standardOutput: outcome.standardOutput,
                standardError: outcome.standardError
            )
        case .rawWrite:
            guard let rawWrite = request.rawWrite else {
                throw HelperError.malformedRequest
            }
            let result = try await performRawWrite(rawWrite, operationID: request.operationID, controller: controller)
            try await emitEvent(
                PrivilegedWorkerEvent(
                    operationID: request.operationID,
                    kind: .finished,
                    phase: rawWrite.phase,
                    helperPID: getpid(),
                    childPID: result.childPID,
                    bytesCompleted: result.bytesTransferred,
                    totalBytes: rawWrite.expectedBytes
                )
            )
            return result
        case .rawCapture:
            guard let rawCapture = request.rawCapture else {
                throw HelperError.malformedRequest
            }
            let result = try await performRawCapture(rawCapture, operationID: request.operationID, controller: controller)
            try await emitEvent(
                PrivilegedWorkerEvent(
                    operationID: request.operationID,
                    kind: .finished,
                    phase: rawCapture.phase,
                    helperPID: getpid(),
                    bytesCompleted: result.bytesTransferred,
                    totalBytes: rawCapture.expectedBytes
                )
            )
            return result
        }
    }

    private func performRawWrite(
        _ request: PrivilegedRawWriteRequest,
        operationID: String,
        controller: OperationController
    ) async throws -> PrivilegedHelperResponse {
        try mirrorTargetChecks(expectation: request.targetExpectation)

        let destinationFD = open(request.destinationDeviceNode, O_WRONLY)
        guard destinationFD >= 0 else {
            throw HelperError.failed("Unable to open \(request.destinationDeviceNode) for writing.")
        }
        defer { close(destinationFD) }

        let stderrPipe = Pipe()
        var child: Process?
        var inputFD: Int32 = -1
        var stderrTask: Task<String, Never>?
        var childPID: Int32?

        if let sourceFilePath = request.sourceFilePath {
            inputFD = open(sourceFilePath, O_RDONLY)
            guard inputFD >= 0 else {
                throw HelperError.failed("Unable to open \(sourceFilePath) for reading.")
            }
        } else if let executablePath = request.streamExecutablePath {
            let stdoutPipe = Pipe()
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executablePath)
            process.arguments = request.streamArguments
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe
            try process.run()
            controller.register(process: process)
            child = process
            childPID = process.processIdentifier
            inputFD = stdoutPipe.fileHandleForReading.fileDescriptor
            stderrTask = Task {
                String(decoding: stderrPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            }
            try await emitEvent(
                PrivilegedWorkerEvent(
                    operationID: operationID,
                    kind: .childStarted,
                    phase: request.phase,
                    helperPID: getpid(),
                    childPID: process.processIdentifier,
                    command: [executablePath] + request.streamArguments,
                    message: request.message
                )
            )
        } else {
            throw HelperError.malformedRequest
        }

        defer {
            if request.sourceFilePath != nil, inputFD >= 0 {
                close(inputFD)
            }
        }

        let totalBytes = request.expectedBytes
        let bytesTransferred = try await pumpBytes(
            operationID: operationID,
            phase: request.phase,
            sourceFD: inputFD,
            destinationFD: destinationFD,
            totalBytes: totalBytes,
            controller: controller
        )

        if let child {
            child.waitUntilExit()
            controller.unregisterProcess()
            let standardError = await stderrTask?.value ?? ""
            guard child.terminationStatus == 0 else {
                throw HelperError.failed("The streamed decompression worker failed: \(standardError.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
            return PrivilegedHelperResponse(
                helperPID: getpid(),
                childPID: childPID,
                bytesTransferred: bytesTransferred,
                standardError: standardError
            )
        }

        return PrivilegedHelperResponse(helperPID: getpid(), bytesTransferred: bytesTransferred)
    }

    private func performRawCapture(
        _ request: PrivilegedRawCaptureRequest,
        operationID: String,
        controller: OperationController
    ) async throws -> PrivilegedHelperResponse {
        try mirrorTargetChecks(expectation: request.targetExpectation)

        let sourceFD = open(request.sourceDeviceNode, O_RDONLY)
        guard sourceFD >= 0 else {
            throw HelperError.failed("Unable to open \(request.sourceDeviceNode) for reading.")
        }
        defer { close(sourceFD) }

        let destinationFD = open(request.destinationFilePath, O_CREAT | O_TRUNC | O_WRONLY, S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH)
        guard destinationFD >= 0 else {
            throw HelperError.failed("Unable to create \(request.destinationFilePath).")
        }
        defer { close(destinationFD) }

        let bytesTransferred = try await pumpBytes(
            operationID: operationID,
            phase: request.phase,
            sourceFD: sourceFD,
            destinationFD: destinationFD,
            totalBytes: request.expectedBytes,
            controller: controller,
            stopAfterTotalBytes: true
        )

        return PrivilegedHelperResponse(helperPID: getpid(), bytesTransferred: bytesTransferred)
    }

    private func pumpBytes(
        operationID: String,
        phase: String,
        sourceFD: Int32,
        destinationFD: Int32,
        totalBytes: Int64?,
        controller: OperationController,
        stopAfterTotalBytes: Bool = false
    ) async throws -> Int64 {
        let bufferSize = 4 * 1024 * 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        let start = Date()
        var lastEmit = Date.distantPast
        var transferred: Int64 = 0

        while true {
            if controller.isCancelled {
                throw HelperError.cancelled
            }

            if stopAfterTotalBytes, let totalBytes, transferred >= totalBytes {
                break
            }

            let bytesToRead: Int
            if stopAfterTotalBytes, let totalBytes {
                let remaining = max(totalBytes - transferred, 0)
                bytesToRead = min(bufferSize, Int(remaining))
                if bytesToRead == 0 {
                    break
                }
            } else {
                bytesToRead = bufferSize
            }

            let readCount = read(sourceFD, buffer, bytesToRead)
            if readCount < 0 {
                throw HelperError.failed("A privileged device copy failed while reading input bytes.")
            }
            if readCount == 0 {
                break
            }

            var written = 0
            while written < readCount {
                if controller.isCancelled {
                    throw HelperError.cancelled
                }
                let writeCount = write(destinationFD, buffer.advanced(by: written), readCount - written)
                if writeCount < 0 {
                    throw HelperError.failed("A privileged device copy failed while writing output bytes.")
                }
                written += writeCount
            }

            transferred += Int64(readCount)
            let now = Date()
            if now.timeIntervalSince(lastEmit) >= 0.2 {
                let elapsed = max(now.timeIntervalSince(start), 0.001)
                try await emitEvent(
                    PrivilegedWorkerEvent(
                        operationID: operationID,
                        kind: .progress,
                        phase: phase,
                        helperPID: getpid(),
                        bytesCompleted: transferred,
                        totalBytes: totalBytes,
                        rateBytesPerSecond: Double(transferred) / elapsed
                    )
                )
                lastEmit = now
            }
        }

        fsync(destinationFD)
        let elapsed = max(Date().timeIntervalSince(start), 0.001)
        try await emitEvent(
            PrivilegedWorkerEvent(
                operationID: operationID,
                kind: .progress,
                phase: phase,
                helperPID: getpid(),
                bytesCompleted: transferred,
                totalBytes: totalBytes,
                rateBytesPerSecond: Double(transferred) / elapsed
            )
        )
        return transferred
    }

    private func runSubprocess(
        _ request: PrivilegedSubprocessRequest,
        operationID: String,
        controller: OperationController
    ) async throws -> SubprocessOutcome {
        let process = Process()
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.executableURL = URL(fileURLWithPath: request.executablePath)
        process.arguments = request.arguments
        process.currentDirectoryURL = request.currentDirectoryPath.map(URL.init(fileURLWithPath:))
        process.standardOutput = standardOutput
        process.standardError = standardError
        try process.run()
        controller.register(process: process)

        try await emitEvent(
            PrivilegedWorkerEvent(
                operationID: operationID,
                kind: .childStarted,
                phase: request.phase,
                helperPID: getpid(),
                childPID: process.processIdentifier,
                command: [request.executablePath] + request.arguments,
                message: request.message
            )
        )

        let parser: ProgressParser = switch request.progressParser {
        case .none:
            .none
        case .ntfsPopulate:
            .ntfsPopulate(expectedTotalBytes: request.expectedTotalBytes)
        }

        let stdoutTask = Task<Data, Never> {
            await self.consumeOutput(
                from: standardOutput.fileHandleForReading,
                parser: parser,
                operationID: operationID,
                phase: request.phase,
                controller: controller
            )
        }
        let stderrTask = Task<Data, Never> {
            await self.consumeOutput(
                from: standardError.fileHandleForReading,
                parser: .none,
                operationID: operationID,
                phase: request.phase,
                controller: controller
            )
        }

        process.waitUntilExit()
        controller.unregisterProcess()

        let output = await stdoutTask.value
        let error = await stderrTask.value
        let standardErrorText = String(decoding: error, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            let trimmed = standardErrorText.trimmingCharacters(in: .whitespacesAndNewlines)
            throw HelperError.failed(trimmed.isEmpty ? "\(request.executablePath) exited with status \(process.terminationStatus)." : trimmed)
        }

        return SubprocessOutcome(
            childPID: process.processIdentifier,
            standardOutput: String(decoding: output, as: UTF8.self),
            standardError: standardErrorText
        )
    }

    private func consumeOutput(
        from handle: FileHandle,
        parser: ProgressParser,
        operationID: String,
        phase: String,
        controller: OperationController
    ) async -> Data {
        var data = Data()
        var lineBuffer = Data()

        while true {
            if controller.isCancelled {
                break
            }
            let chunk = handle.availableData
            if chunk.isEmpty {
                break
            }
            data.append(chunk)

            switch parser {
            case .none:
                break
            case let .ntfsPopulate(expectedTotalBytes):
                lineBuffer.append(chunk)
                while let newlineRange = lineBuffer.firstRange(of: Data([0x0A])) {
                    let lineData = lineBuffer.subdata(in: 0..<newlineRange.lowerBound)
                    lineBuffer.removeSubrange(0...newlineRange.lowerBound)
                    if let line = String(data: lineData, encoding: .utf8) {
                        try? await emitNTFSPopulateEvent(
                            line: line,
                            expectedTotalBytes: expectedTotalBytes,
                            operationID: operationID,
                            phase: phase
                        )
                    }
                }
            }
        }

        if case let .ntfsPopulate(expectedTotalBytes) = parser,
           !lineBuffer.isEmpty,
           let line = String(data: lineBuffer, encoding: .utf8) {
            try? await emitNTFSPopulateEvent(
                line: line,
                expectedTotalBytes: expectedTotalBytes,
                operationID: operationID,
                phase: phase
            )
        }

        return data
    }

    private func emitNTFSPopulateEvent(
        line: String,
        expectedTotalBytes: Int64?,
        operationID: String,
        phase: String
    ) async throws {
        guard line.hasPrefix("FLASHKIT_PROGRESS\t") else {
            return
        }

        let components = line.split(separator: "\t", omittingEmptySubsequences: false)
        guard components.count >= 4,
              let completed = Int64(components[1]),
              let total = Int64(components[2])
        else {
            return
        }

        let message = String(components[3])
        try await emitEvent(
            PrivilegedWorkerEvent(
                operationID: operationID,
                kind: .progress,
                phase: phase,
                helperPID: getpid(),
                message: message,
                bytesCompleted: completed,
                totalBytes: expectedTotalBytes ?? total
            )
        )
    }

    private func mirrorTargetChecks(expectation: PrivilegedTargetExpectation?) throws {
        guard let expectation else {
            return
        }

        let wholeDiskNode = normalizeDeviceNode(expectation.expectedDeviceNode)
        if expectation.forceUnmountWholeDisk {
            _ = try runCommandCapture("/usr/sbin/diskutil", arguments: ["unmountDisk", "force", wholeDiskNode])
        }

        let infoData = try runCommandCapture("/usr/sbin/diskutil", arguments: ["info", "-plist", wholeDiskNode]).standardOutput
        guard let plist = try PropertyListSerialization.propertyList(from: infoData, format: nil) as? [String: Any] else {
            throw HelperError.targetMismatch("The privileged helper could not read fresh disk metadata for \(wholeDiskNode).")
        }

        let actualDeviceNode = normalizeDeviceNode((plist["DeviceNode"] as? String) ?? wholeDiskNode)
        guard actualDeviceNode == wholeDiskNode else {
            throw HelperError.targetMismatch("The privileged helper revalidated a different target device than FlashKit selected.")
        }

        if expectation.expectedWholeDisk {
            let wholeDisk = plist["WholeDisk"] as? Bool ?? false
            guard wholeDisk else {
                throw HelperError.targetMismatch("The privileged helper no longer sees the selected target as a whole removable disk.")
            }
        }

        if expectation.requireWritable {
            let writable = plist["WritableMedia"] as? Bool ?? true
            guard writable else {
                throw HelperError.targetMismatch("The privileged helper found that the selected target is no longer writable.")
            }
        }

        if let expectedSize = expectation.expectedSizeBytes {
            let actualSize = (plist["TotalSize"] as? NSNumber)?.int64Value
                ?? (plist["Size"] as? NSNumber)?.int64Value
            guard actualSize == expectedSize else {
                throw HelperError.targetMismatch("The privileged helper found that the selected target changed size before writing began.")
            }
        }

        if expectation.requireRemovable {
            let isInternal = plist["Internal"] as? Bool ?? false
            let isRemovable = plist["Removable"] as? Bool ?? (plist["RemovableMedia"] as? Bool ?? false)
            if isInternal || !isRemovable {
                if !(expectation.allowUnsafeTargetsWithExpertOverride && expectation.expertOverrideEnabled) {
                    throw HelperError.targetMismatch("The privileged helper refused to open an internal or non-removable target without an expert override.")
                }
            }
        }
    }

    private func runCommandCapture(_ executable: String, arguments: [String]) throws -> ProcessResult {
        let process = Process()
        let output = Pipe()
        let error = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = error
        try process.run()
        process.waitUntilExit()

        let standardOutput = output.fileHandleForReading.readDataToEndOfFile()
        let standardError = error.fileHandleForReading.readDataToEndOfFile()
        if process.terminationStatus != 0 {
            let message = String(decoding: standardError, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw HelperError.failed(message.isEmpty ? "\(executable) exited with status \(process.terminationStatus)." : message)
        }

        return ProcessResult(standardOutput: standardOutput, standardError: standardError)
    }

    private func emitEvent(_ event: PrivilegedWorkerEvent) async throws {
        let proxy = connection.remoteObjectProxyWithErrorHandler { _ in } as? FlashKitPrivilegedProgressXPC
        guard let proxy else {
            return
        }
        let eventData = try encoder.encode(event)
        proxy.publishEvent(eventData)
    }

    private func register(_ controller: OperationController, for operationID: String) {
        operationsLock.lock()
        operations[operationID] = controller
        operationsLock.unlock()
    }

    private func unregisterController(for operationID: String) {
        operationsLock.lock()
        operations.removeValue(forKey: operationID)
        operationsLock.unlock()
    }

    private func phase(for request: PrivilegedHelperRequest) -> String {
        switch request.kind {
        case .subprocess:
            return request.subprocess?.phase ?? "Privileged work"
        case .rawWrite:
            return request.rawWrite?.phase ?? "Privileged work"
        case .rawCapture:
            return request.rawCapture?.phase ?? "Privileged work"
        }
    }

    private func message(for request: PrivilegedHelperRequest) -> String {
        switch request.kind {
        case .subprocess:
            return request.subprocess?.message ?? "Starting privileged work."
        case .rawWrite:
            return request.rawWrite?.message ?? "Starting privileged work."
        case .rawCapture:
            return request.rawCapture?.message ?? "Starting privileged work."
        }
    }

    private func normalizeDeviceNode(_ deviceNode: String) -> String {
        deviceNode.replacingOccurrences(of: "/dev/rdisk", with: "/dev/disk")
    }
}

private struct ProcessResult {
    let standardOutput: Data
    let standardError: Data
}

private final class HelperListenerDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        let exportedInterface = NSXPCInterface(with: FlashKitPrivilegedHelperXPC.self)
        let remoteInterface = NSXPCInterface(with: FlashKitPrivilegedProgressXPC.self)
        newConnection.exportedInterface = exportedInterface
        newConnection.remoteObjectInterface = remoteInterface
        newConnection.exportedObject = PrivilegedHelperService(connection: newConnection)
        newConnection.resume()
        return true
    }
}

private let delegate = HelperListenerDelegate()
private let listener = NSXPCListener(machServiceName: PrivilegedHelperConstants.machServiceName)
listener.delegate = delegate
listener.resume()
RunLoop.current.run()
