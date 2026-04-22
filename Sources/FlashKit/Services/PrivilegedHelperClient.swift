import FlashKitHelperProtocol
import Foundation

typealias PrivilegedWorkerEventHandler = @Sendable (PrivilegedWorkerEvent) async -> Void

struct PrivilegedOperationResult: Sendable {
    let helperProtocolVersion: Int
    let helperPID: Int32
    let childPID: Int32?
    let bytesTransferred: Int64?
    let standardOutput: String
    let standardError: String
}

protocol PrivilegedOperationClient: Sendable {
    func runSubprocess(
        executable: String,
        arguments: [String],
        currentDirectory: URL?,
        progressParser: PrivilegedSubprocessProgressParser,
        expectedTotalBytes: Int64?,
        phase: String,
        message: String,
        eventHandler: PrivilegedWorkerEventHandler?
    ) async throws -> PrivilegedOperationResult

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
    ) async throws -> PrivilegedOperationResult

    func captureRaw(
        sourceDeviceNode: String,
        destinationFilePath: String,
        expectedBytes: Int64,
        phase: String,
        message: String,
        targetExpectation: PrivilegedTargetExpectation?,
        eventHandler: PrivilegedWorkerEventHandler?
    ) async throws -> PrivilegedOperationResult
}

enum PrivilegedHelperClientError: LocalizedError {
    case helperUnavailable
    case invalidResponse
    case remoteFailure(String)
    case protocolMismatch

    var errorDescription: String? {
        switch self {
        case .helperUnavailable:
            return "FlashKit's privileged helper is not installed or is unavailable. Install or bootstrap the helper before writing removable media."
        case .invalidResponse:
            return "FlashKit's privileged helper returned an invalid response."
        case let .remoteFailure(message):
            return message
        case .protocolMismatch:
            return "FlashKit's privileged helper protocol does not match this build. Reinstall the helper from the current source tree."
        }
    }

    var shouldFallbackToPasswordPrompt: Bool {
        switch self {
        case .helperUnavailable, .protocolMismatch:
            return true
        case .invalidResponse, .remoteFailure:
            return false
        }
    }
}

private final class XPCOperationState: @unchecked Sendable {
    private let lock = NSLock()
    private var connection: NSXPCConnection?
    private var operationID: String?
    private var continuation: CheckedContinuation<PrivilegedOperationResult, Error>?

    func register(
        connection: NSXPCConnection,
        operationID: String,
        continuation: CheckedContinuation<PrivilegedOperationResult, Error>
    ) {
        lock.lock()
        self.connection = connection
        self.operationID = operationID
        self.continuation = continuation
        lock.unlock()
    }

    func resume(with result: Result<PrivilegedOperationResult, Error>) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        let connection = self.connection
        self.connection = nil
        self.operationID = nil
        lock.unlock()

        connection?.invalidate()
        continuation?.resume(with: result)
    }

    func cancel() {
        lock.lock()
        let connection = self.connection
        let operationID = self.operationID
        let continuation = self.continuation
        self.connection = nil
        self.operationID = nil
        self.continuation = nil
        lock.unlock()

        if let connection, let operationID {
            let proxy = connection.remoteObjectProxyWithErrorHandler { _ in } as? FlashKitPrivilegedHelperXPC
            proxy?.cancelOperation(operationID) { _ in }
            connection.invalidate()
        }

        continuation?.resume(throwing: CancellationError())
    }
}

private final class PrivilegedHelperProgressReceiver: NSObject, FlashKitPrivilegedProgressXPC {
    private let eventHandler: PrivilegedWorkerEventHandler?
    private let decoder = JSONDecoder()

    init(eventHandler: PrivilegedWorkerEventHandler?) {
        self.eventHandler = eventHandler
    }

    func publishEvent(_ eventData: Data) {
        guard let eventHandler else {
            return
        }

        guard let event = try? decoder.decode(PrivilegedWorkerEvent.self, from: eventData),
              event.protocolVersion == PrivilegedHelperConstants.protocolVersion
        else {
            return
        }

        Task {
            await eventHandler(event)
        }
    }
}

struct PrivilegedHelperClient: PrivilegedOperationClient {
    private func perform(
        _ request: PrivilegedHelperRequest,
        eventHandler: PrivilegedWorkerEventHandler?
    ) async throws -> PrivilegedOperationResult {
        let requestData = try JSONEncoder().encode(request)
        let state = XPCOperationState()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let connection = NSXPCConnection(
                    machServiceName: PrivilegedHelperConstants.machServiceName,
                    options: .privileged
                )
                connection.remoteObjectInterface = NSXPCInterface(with: FlashKitPrivilegedHelperXPC.self)
                connection.exportedInterface = NSXPCInterface(with: FlashKitPrivilegedProgressXPC.self)
                connection.exportedObject = PrivilegedHelperProgressReceiver(eventHandler: eventHandler)

                connection.interruptionHandler = {
                    state.resume(with: .failure(PrivilegedHelperClientError.helperUnavailable))
                }
                connection.invalidationHandler = {}
                connection.resume()

                state.register(connection: connection, operationID: request.operationID, continuation: continuation)

                let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                    let wrapped = (error as NSError).domain == NSCocoaErrorDomain
                        ? PrivilegedHelperClientError.helperUnavailable
                        : PrivilegedHelperClientError.remoteFailure(error.localizedDescription)
                    state.resume(with: .failure(wrapped))
                } as? FlashKitPrivilegedHelperXPC

                proxy?.performRequest(requestData) { responseData, errorMessage in
                    if let errorMessage, !errorMessage.isEmpty {
                        let wrapped: Error = if errorMessage.contains("protocol") {
                            PrivilegedHelperClientError.protocolMismatch
                        } else {
                            PrivilegedHelperClientError.remoteFailure(errorMessage)
                        }
                        state.resume(with: .failure(wrapped))
                        return
                    }

                    guard let responseData,
                          let response = try? JSONDecoder().decode(PrivilegedHelperResponse.self, from: responseData)
                    else {
                        state.resume(with: .failure(PrivilegedHelperClientError.invalidResponse))
                        return
                    }

                    guard response.protocolVersion == PrivilegedHelperConstants.protocolVersion else {
                        state.resume(with: .failure(PrivilegedHelperClientError.protocolMismatch))
                        return
                    }

                    state.resume(
                        with: .success(
                            PrivilegedOperationResult(
                                helperProtocolVersion: response.protocolVersion,
                                helperPID: response.helperPID,
                                childPID: response.childPID,
                                bytesTransferred: response.bytesTransferred,
                                standardOutput: response.standardOutput,
                                standardError: response.standardError
                            )
                        )
                    )
                }
            }
        } onCancel: {
            state.cancel()
        }
    }

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
        try await perform(
            PrivilegedHelperRequest(
                operationID: UUID().uuidString,
                subprocess: PrivilegedSubprocessRequest(
                    executablePath: executable,
                    arguments: arguments,
                    currentDirectoryPath: currentDirectory?.path(),
                    progressParser: progressParser,
                    expectedTotalBytes: expectedTotalBytes,
                    phase: phase,
                    message: message
                )
            ),
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
        try await perform(
            PrivilegedHelperRequest(
                operationID: UUID().uuidString,
                rawWrite: PrivilegedRawWriteRequest(
                    destinationDeviceNode: destinationDeviceNode,
                    sourceFilePath: sourceFilePath,
                    streamExecutablePath: streamExecutablePath,
                    streamArguments: streamArguments,
                    expectedBytes: expectedBytes,
                    phase: phase,
                    message: message,
                    targetExpectation: targetExpectation
                )
            ),
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
        try await perform(
            PrivilegedHelperRequest(
                operationID: UUID().uuidString,
                rawCapture: PrivilegedRawCaptureRequest(
                    sourceDeviceNode: sourceDeviceNode,
                    destinationFilePath: destinationFilePath,
                    expectedBytes: expectedBytes,
                    phase: phase,
                    message: message,
                    targetExpectation: targetExpectation
                )
            ),
            eventHandler: eventHandler
        )
    }
}
