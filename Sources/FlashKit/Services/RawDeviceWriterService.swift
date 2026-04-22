import FlashKitHelperProtocol
import Foundation

struct RawDeviceWriterService {
    private let privileged: PrivilegedCommandService

    init(privileged: PrivilegedCommandService = PrivilegedCommandService()) {
        self.privileged = privileged
    }

    func write(
        input: RawWriteInput,
        to rawDeviceNode: String,
        expectedBytes: Int64?,
        targetExpectation: PrivilegedTargetExpectation?,
        phase: String,
        message: String,
        eventHandler: PrivilegedWorkerEventHandler? = nil
    ) async throws -> PrivilegedOperationResult {
        do {
            return try await privileged.writeRaw(
                input: input,
                to: rawDeviceNode,
                expectedBytes: expectedBytes,
                phase: phase,
                message: message,
                targetExpectation: targetExpectation,
                eventHandler: eventHandler
            )
        } catch let error as PrivilegedHelperClientError {
            throw error
        } catch {
            if let compression = input.streamingCompression {
                throw BackendWritePipelineError.decompressionStreamFailure(
                    "The \(compression.displayName)-compressed raw image could not be streamed into the target device."
                )
            }
            throw error
        }
    }
}
