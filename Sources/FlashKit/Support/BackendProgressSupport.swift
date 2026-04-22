import FlashKitHelperProtocol
import Foundation

struct BackendPhaseRange: Sendable {
    let start: Double
    let end: Double

    func mappedFraction(completedBytes: Int64, totalBytes: Int64) -> Double {
        guard totalBytes > 0 else {
            return start
        }

        let normalized = min(max(Double(completedBytes) / Double(totalBytes), 0), 1)
        return start + ((end - start) * normalized)
    }
}

struct BackendWorkerRuntimeTelemetry: Sendable {
    let helperProtocolVersion: Int
    let helperPID: Int32
    let workerPID: Int32?
    let workerCommand: [String]?
}

actor WorkerProgressBridge {
    private let phase: String
    private let baseMessage: String
    private let range: BackendPhaseRange
    private let progress: @Sendable (WriteSessionUpdate) async -> Void
    private let protocolVersion: Int
    private var lastProgressBucket = -1
    private var lastByteCheckpoint: Int64 = -1
    private var currentFraction: Double?
    private var latestTelemetry: BackendWorkerRuntimeTelemetry?

    init(
        phase: String,
        baseMessage: String,
        range: BackendPhaseRange,
        protocolVersion: Int = PrivilegedHelperConstants.protocolVersion,
        progress: @escaping @Sendable (WriteSessionUpdate) async -> Void
    ) {
        self.phase = phase
        self.baseMessage = baseMessage
        self.range = range
        self.progress = progress
        self.protocolVersion = protocolVersion
        currentFraction = range.start
    }

    func handleWorkerEvent(_ event: PrivilegedWorkerEvent) async {
        switch event.kind {
        case .helperStarted:
            await emitWorkerLines(
                helperPID: event.helperPID,
                workerPID: nil,
                command: nil,
                mode: "helper"
            )
        case .childStarted:
            await emitWorkerLines(
                helperPID: event.helperPID,
                workerPID: event.childPID,
                command: event.command,
                mode: "subprocess"
            )
        case .progress:
            await reportBytes(
                completedBytes: event.bytesCompleted,
                totalBytes: event.totalBytes,
                message: event.message,
                rateBytesPerSecond: event.rateBytesPerSecond
            )
        case .message:
            if let message = event.message {
                await emitDetails(["[WORKER] message=\(message)"])
            }
        case .finished:
            break
        case .failed:
            if let failureReason = event.failureReason {
                await emitDetails(["[WORKER] failure=\(failureReason)"])
            }
        }
    }

    func reportBytes(
        completedBytes: Int64?,
        totalBytes: Int64?,
        message: String?,
        rateBytesPerSecond: Double?
    ) async {
        guard let completedBytes, let totalBytes, totalBytes > 0 else {
            return
        }

        let mapped = range.mappedFraction(completedBytes: completedBytes, totalBytes: totalBytes)
        currentFraction = mapped

        var details: [String] = []
        let bucket = Int((Double(completedBytes) / Double(totalBytes)) * 10)
        let checkpointBytes = completedBytes / (128 * 1024 * 1024)

        if bucket != lastProgressBucket || checkpointBytes != lastByteCheckpoint {
            details = BackendActivityLogFormatter.progressLines(
                phase: phase,
                completedBytes: completedBytes,
                totalBytes: totalBytes,
                rateBytesPerSecond: rateBytesPerSecond
            )
            lastProgressBucket = bucket
            lastByteCheckpoint = checkpointBytes
        }

        await progress(
            .init(
                phase: phase,
                message: message ?? baseMessage,
                fractionCompleted: mapped,
                details: details,
                shouldLogMessage: false
            )
        )
    }

    func emitWorkerLines(
        helperPID: Int32,
        workerPID: Int32?,
        command: [String]?,
        mode: String
    ) async {
        let telemetry = BackendWorkerRuntimeTelemetry(
            helperProtocolVersion: protocolVersion,
            helperPID: helperPID,
            workerPID: workerPID,
            workerCommand: command
        )
        latestTelemetry = telemetry
        let details = BackendActivityLogFormatter.workerLines(telemetry, mode: mode)
        await emitDetails(details)
    }

    func emitLocalWorkerLines(processID: Int32, command: [String], mode: String) async {
        let telemetry = BackendWorkerRuntimeTelemetry(
            helperProtocolVersion: protocolVersion,
            helperPID: 0,
            workerPID: processID,
            workerCommand: command
        )
        latestTelemetry = telemetry
        await emitDetails(BackendActivityLogFormatter.workerLines(telemetry, mode: mode))
    }

    func snapshotTelemetry() -> BackendWorkerRuntimeTelemetry? {
        latestTelemetry
    }

    func emitDetails(_ details: [String]) async {
        guard !details.isEmpty else {
            return
        }

        await progress(
            .init(
                phase: phase,
                message: baseMessage,
                fractionCompleted: currentFraction ?? range.start,
                details: details,
                shouldLogMessage: false
            )
        )
    }
}
