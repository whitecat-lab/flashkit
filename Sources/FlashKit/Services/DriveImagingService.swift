import FlashKitHelperProtocol
import Foundation
import OSLog

enum DriveImagingServiceError: LocalizedError {
    case missingHelper(HelperTool)
    case sourceImageTooLarge(sourceBytes: Int64, diskBytes: Int64)
    case sourceStagingFailed(String)
    case removableVolumePermissionDenied(String)

    var errorDescription: String? {
        switch self {
        case let .missingHelper(tool):
            return "The helper \(tool.rawValue) is required for this drive imaging operation."
        case let .sourceImageTooLarge(sourceBytes, diskBytes):
            return "The prepared raw image is \(ByteCountFormatter.string(fromByteCount: sourceBytes, countStyle: .file)), which is larger than the selected USB drive (\(ByteCountFormatter.string(fromByteCount: diskBytes, countStyle: .file)))."
        case let .sourceStagingFailed(message):
            return message
        case let .removableVolumePermissionDenied(message):
            return message
        }
    }
}

struct DriveImagingService {
    private let logger = Logger(subsystem: "FlashKit", category: "DriveImagingWrite")
    private let privileged = PrivilegedCommandService()
    private let runner = ProcessRunner()
    private let diskService = DiskService()
    private let verificationService = VerificationService()
    private let rawDiskImageService = RawDiskImageService()
    private let rawDeviceWriter = RawDeviceWriterService()
    private let postWriteValidationService = PostWriteValidationService()
    private let ntfsPopulateService = NTFSPopulateService()

    func restoreImage(
        sourceProfile: SourceImageProfile,
        sourceURL: URL,
        plan: WritePlan,
        targetDisk: ExternalDisk,
        options: WriteOptions,
        toolchain: ToolchainStatus,
        executionMetadata: BackendWriteExecutionMetadata? = nil,
        progress: @escaping @Sendable (WriteSessionUpdate) async -> Void
    ) async throws {
        let rawDeviceNode = targetDisk.deviceNode.replacingOccurrences(of: "/dev/disk", with: "/dev/rdisk")
        var verificationInput: RawWriteInput?
        let preferStreaming = executionMetadata?.decompressionStreamingActive ?? true
        let helperTargetExpectation = privilegedTargetExpectation(for: targetDisk, options: options)
        var runtimeExecutionMetadata = executionMetadata
        var stagedSourceCleanup: (@Sendable () -> Void)?
        defer {
            stagedSourceCleanup?()
        }

        if sourceProfile.format == .dd {
            let rawInput = try await rawDiskImageService.writeInput(
                for: sourceURL,
                toolchain: toolchain,
                preferStreaming: preferStreaming
            )
            let preparedSize = rawInput.logicalSizeHint ?? sourceProfile.size
            if preparedSize > 0, preparedSize > targetDisk.size {
                throw DriveImagingServiceError.sourceImageTooLarge(sourceBytes: preparedSize, diskBytes: targetDisk.size)
            }
            verificationInput = rawInput
        }

        logger.info("phase=unmounting image=\(sourceProfile.displayName, privacy: .public) target=\(targetDisk.deviceNode, privacy: .public)")
        await progress(.init(phase: "Preparing target disk", message: "Unmounting \(targetDisk.deviceNode).", fractionCompleted: 0.12))
        await progress(
            .init(
                phase: "Preparing target disk",
                message: "Preparing the raw-device restore path.",
                fractionCompleted: 0.14,
                details: BackendActivityLogFormatter.partitionWriteLines(for: plan, volumeLabel: "")
            )
        )
        try await requestRemovableVolumeAccessIfNeeded(targetDisk)
        try await prepareTargetForRawWrite(targetDisk)

        switch sourceProfile.format {
        case .dd:
            let restoreMessage = if executionMetadata?.decompressionStreamingActive == true,
                                    let compression = verificationInput?.streamingCompression {
                "Streaming the \(compression.displayName)-compressed raw image into the raw device."
            } else {
                "Writing the raw image to the raw device."
            }
            logger.info("phase=restoring image=\(sourceProfile.displayName, privacy: .public) target=\(targetDisk.deviceNode, privacy: .public) mode=raw")
            await progress(.init(phase: "Restoring image", message: restoreMessage, fractionCompleted: 0.22))
            if let verificationInput {
                let restoreBridge = WorkerProgressBridge(
                    phase: "Restoring image",
                    baseMessage: restoreMessage,
                    range: BackendPhaseRange(start: 0.22, end: 0.90),
                    progress: progress
                )
                _ = try await writeRawInput(
                    verificationInput,
                    to: rawDeviceNode,
                    expectedBytes: verificationInput.logicalSizeHint ?? sourceProfile.size,
                    targetExpectation: helperTargetExpectation,
                    phase: "Restoring image",
                    message: restoreMessage,
                    restoreBridge: restoreBridge
                )
                if let telemetry = await restoreBridge.snapshotTelemetry() {
                    runtimeExecutionMetadata = runtimeExecutionMetadata?.applying(workerTelemetry: telemetry)
                }
            }
        case .iso, .udfISO, .dmg, .unknown:
            logger.info("phase=restoring image=\(sourceProfile.displayName, privacy: .public) target=\(targetDisk.deviceNode, privacy: .public) mode=direct")
            await progress(.init(phase: "Staging source", message: "Preparing the source image for the raw-device writer.", fractionCompleted: 0.18))
            let stagedSource = try await stageSourceForPrivilegedRead(sourceURL) { copied, total, message in
                let fraction = 0.16 + (Double(copied) / Double(max(total, 1)) * 0.04)
                await progress(.init(phase: "Staging source", message: message, fractionCompleted: fraction, completedBytes: copied, totalBytes: total))
            }
            stagedSourceCleanup = stagedSource.cleanup
            await progress(.init(phase: "Restoring image", message: "Writing the source image to the raw device.", fractionCompleted: 0.20))
            let rawInput = RawWriteInput.file(stagedSource.url)
            let restoreBridge = WorkerProgressBridge(
                phase: "Restoring image",
                baseMessage: "Writing the source image to the raw device.",
                range: BackendPhaseRange(start: 0.20, end: 0.90),
                progress: progress
            )
            _ = try await writeRawInput(
                rawInput,
                to: rawDeviceNode,
                expectedBytes: rawInput.logicalSizeHint ?? sourceProfile.size,
                targetExpectation: helperTargetExpectation,
                phase: "Restoring image",
                message: "Writing the source image to the raw device.",
                restoreBridge: restoreBridge
            )
            if let telemetry = await restoreBridge.snapshotTelemetry() {
                runtimeExecutionMetadata = runtimeExecutionMetadata?.applying(workerTelemetry: telemetry)
            }
            verificationInput = rawInput
        case .vhd, .vhdx:
            guard let qemuImg = toolchain.path(for: .qemuImg) else {
                throw DriveImagingServiceError.missingHelper(.qemuImg)
            }
            let tempRaw = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString).appendingPathExtension("img")
            _ = try await runner.run(qemuImg, arguments: ["convert", "-O", "raw", sourceURL.path(), tempRaw.path()])
            defer { try? FileManager.default.removeItem(at: tempRaw) }
            let rawInput = RawWriteInput.file(tempRaw)
            logger.info("phase=restoring image=\(sourceProfile.displayName, privacy: .public) target=\(targetDisk.deviceNode, privacy: .public) mode=qemu-convert")
            let restoreBridge = WorkerProgressBridge(
                phase: "Restoring image",
                baseMessage: "Writing the converted raw image to the device.",
                range: BackendPhaseRange(start: 0.22, end: 0.90),
                progress: progress
            )
            _ = try await writeRawInput(
                rawInput,
                to: rawDeviceNode,
                expectedBytes: rawInput.logicalSizeHint,
                targetExpectation: helperTargetExpectation,
                phase: "Restoring image",
                message: "Writing the converted raw image to the device.",
                restoreBridge: restoreBridge
            )
            if let telemetry = await restoreBridge.snapshotTelemetry() {
                runtimeExecutionMetadata = runtimeExecutionMetadata?.applying(workerTelemetry: telemetry)
            }
            verificationInput = rawInput
        case .wim, .esd:
            throw DriveImagingServiceError.missingHelper(.wimlibImagex)
        }

        logger.info("phase=verifying image=\(sourceProfile.displayName, privacy: .public) target=\(targetDisk.deviceNode, privacy: .public)")
        await progress(.init(phase: "Verifying", message: "Verifying the restored target.", fractionCompleted: 0.90))
        switch sourceProfile.format {
        case .vhd, .vhdx, .dd, .iso, .udfISO, .dmg, .unknown:
            if let verificationInput {
                try await verificationService.verifyWrittenRawInput(
                    verificationInput,
                    destinationDeviceNode: rawDeviceNode
                )
            }
        case .wim, .esd:
            break
        }

        logger.info("phase=validating image=\(sourceProfile.displayName, privacy: .public) target=\(targetDisk.deviceNode, privacy: .public)")
        await progress(.init(phase: "Validating media", message: "Running structural validation on the written target.", fractionCompleted: 0.94))
        let validationResult = await postWriteValidationService.validateWrittenMedia(
            sourceProfile: sourceProfile,
            targetDisk: targetDisk,
            plan: plan,
            executionMetadata: runtimeExecutionMetadata,
            destinationRoot: nil,
            ntfsDestinationPartition: nil,
            customization: options.customizationProfile,
            toolchain: toolchain,
            ntfsPopulateService: ntfsPopulateService
        )
        await progress(
            .init(
                phase: "Validating media",
                message: validationResult.passed ? "Structural validation passed." : (validationResult.failureReason ?? "Structural validation failed."),
                fractionCompleted: 0.95,
                details: BackendActivityLogFormatter.validationLines(validationResult)
            )
        )
        guard validationResult.passed else {
            throw MediaValidationServiceError.failed(validationResult)
        }

        _ = try? await runner.run("/usr/bin/sync", arguments: [])

        if options.ejectWhenFinished {
            await progress(.init(phase: "Ejecting", message: "Ejecting the restored drive.", fractionCompleted: 0.97))
            logger.info("phase=ejecting image=\(sourceProfile.displayName, privacy: .public) target=\(targetDisk.deviceNode, privacy: .public)")
            _ = try? await runner.run("/usr/sbin/diskutil", arguments: ["eject", targetDisk.deviceNode])
        }

        logger.info("phase=finished image=\(sourceProfile.displayName, privacy: .public) target=\(targetDisk.deviceNode, privacy: .public)")
        await progress(.init(phase: "Finished", message: "Drive restore completed.", fractionCompleted: 1.0))
    }

    func captureImage(
        targetDisk: ExternalDisk,
        destinationURL: URL,
        format: DriveCaptureFormat,
        toolchain: ToolchainStatus,
        progress: @escaping @Sendable (WriteSessionUpdate) async -> Void
    ) async throws {
        let rawDeviceNode = targetDisk.deviceNode.replacingOccurrences(of: "/dev/disk", with: "/dev/rdisk")

        await progress(.init(phase: "Capturing drive", message: "Reading \(targetDisk.deviceNode) into \(destinationURL.lastPathComponent).", fractionCompleted: 0.15))
        let helperTargetExpectation = privilegedTargetExpectation(for: targetDisk, options: WriteOptions())

        switch format {
        case .rawImage:
            let captureBridge = WorkerProgressBridge(
                phase: "Capturing drive",
                baseMessage: "Reading \(targetDisk.deviceNode) into \(destinationURL.lastPathComponent).",
                range: BackendPhaseRange(start: 0.15, end: 0.90),
                progress: progress
            )
            _ = try await privileged.captureRaw(
                from: rawDeviceNode,
                to: destinationURL,
                expectedBytes: targetDisk.size,
                phase: "Capturing drive",
                message: "Reading \(targetDisk.deviceNode) into \(destinationURL.lastPathComponent).",
                targetExpectation: helperTargetExpectation,
                eventHandler: { event in
                    await captureBridge.handleWorkerEvent(event)
                }
            )
            await progress(.init(phase: "Verifying", message: "Verifying the captured raw image.", fractionCompleted: 0.90))
            try await verificationService.verifyCapturedImage(
                sourceDeviceNode: rawDeviceNode,
                destinationURL: destinationURL,
                expectedBytes: targetDisk.size
            )
        case .vhd:
            guard let qemuImg = toolchain.path(for: .qemuImg) else {
                throw DriveImagingServiceError.missingHelper(.qemuImg)
            }
            let tempRaw = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("img")
            defer { try? FileManager.default.removeItem(at: tempRaw) }

            let captureBridge = WorkerProgressBridge(
                phase: "Capturing drive",
                baseMessage: "Reading \(targetDisk.deviceNode) into \(tempRaw.lastPathComponent).",
                range: BackendPhaseRange(start: 0.15, end: 0.66),
                progress: progress
            )
            _ = try await privileged.captureRaw(
                from: rawDeviceNode,
                to: tempRaw,
                expectedBytes: targetDisk.size,
                phase: "Capturing drive",
                message: "Reading \(targetDisk.deviceNode) into \(tempRaw.lastPathComponent).",
                targetExpectation: helperTargetExpectation,
                eventHandler: { event in
                    await captureBridge.handleWorkerEvent(event)
                }
            )
            await progress(.init(phase: "Converting", message: "Converting the captured image to VHD.", fractionCompleted: 0.70))
            _ = try await runner.run(
                qemuImg,
                arguments: ["convert", "-O", "vpc", tempRaw.path(), destinationURL.path()]
            )
            await progress(.init(phase: "Verifying", message: "Verifying the captured VHD image.", fractionCompleted: 0.90))
            try await verificationService.verifyQEMUConvertedCapture(
                sourceDeviceNode: rawDeviceNode,
                destinationURL: destinationURL,
                expectedBytes: targetDisk.size,
                qemuImg: qemuImg
            )
        case .vhdx:
            guard let qemuImg = toolchain.path(for: .qemuImg) else {
                throw DriveImagingServiceError.missingHelper(.qemuImg)
            }
            let tempRaw = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("img")
            defer { try? FileManager.default.removeItem(at: tempRaw) }

            let captureBridge = WorkerProgressBridge(
                phase: "Capturing drive",
                baseMessage: "Reading \(targetDisk.deviceNode) into \(tempRaw.lastPathComponent).",
                range: BackendPhaseRange(start: 0.15, end: 0.66),
                progress: progress
            )
            _ = try await privileged.captureRaw(
                from: rawDeviceNode,
                to: tempRaw,
                expectedBytes: targetDisk.size,
                phase: "Capturing drive",
                message: "Reading \(targetDisk.deviceNode) into \(tempRaw.lastPathComponent).",
                targetExpectation: helperTargetExpectation,
                eventHandler: { event in
                    await captureBridge.handleWorkerEvent(event)
                }
            )
            await progress(.init(phase: "Converting", message: "Converting the captured image to VHDX.", fractionCompleted: 0.70))
            _ = try await runner.run(
                qemuImg,
                arguments: ["convert", "-O", "vhdx", tempRaw.path(), destinationURL.path()]
            )
            await progress(.init(phase: "Verifying", message: "Verifying the captured VHDX image.", fractionCompleted: 0.90))
            try await verificationService.verifyVHDXCapture(
                sourceDeviceNode: rawDeviceNode,
                destinationURL: destinationURL,
                expectedBytes: targetDisk.size,
                qemuImg: qemuImg
            )
        }

        _ = try? await runner.run("/usr/bin/sync", arguments: [])
        await progress(.init(phase: "Finished", message: "Drive capture completed.", fractionCompleted: 1.0))
    }

    private func privilegedTargetExpectation(for targetDisk: ExternalDisk, options: WriteOptions) -> PrivilegedTargetExpectation {
        PrivilegedTargetExpectation(
            expectedDeviceNode: targetDisk.deviceNode,
            expectedWholeDisk: true,
            expectedSizeBytes: targetDisk.size,
            requireWritable: targetDisk.writable,
            requireRemovable: true,
            allowUnsafeTargetsWithExpertOverride: true,
            expertOverrideEnabled: options.expertOverrideEnabled,
            forceUnmountWholeDisk: true
        )
    }

    private func writeRawInput(
        _ input: RawWriteInput,
        to rawDeviceNode: String,
        expectedBytes: Int64?,
        targetExpectation: PrivilegedTargetExpectation?,
        phase: String,
        message: String,
        restoreBridge: WorkerProgressBridge
    ) async throws -> PrivilegedOperationResult {
        try await rawDeviceWriter.write(
            input: input,
            to: rawDeviceNode,
            expectedBytes: expectedBytes,
            targetExpectation: targetExpectation,
            phase: phase,
            message: message,
            eventHandler: { event in
                await restoreBridge.handleWorkerEvent(event)
            }
        )
    }

    private func prepareTargetForRawWrite(_ targetDisk: ExternalDisk) async throws {
        let partitions = (try? await diskService.mountedPartitions(forWholeDisk: targetDisk.identifier)) ?? []
        for partition in partitions {
            if partition.mountPoint != nil {
                _ = try? await privileged.run(
                    "/usr/sbin/diskutil",
                    arguments: ["unmount", "force", partition.deviceNode],
                    phase: "Preparing target disk",
                    message: "Unmounting \(partition.deviceNode)."
                )
            }
        }

        _ = try await privileged.run(
            "/usr/sbin/diskutil",
            arguments: ["unmountDisk", "force", targetDisk.deviceNode],
            phase: "Preparing target disk",
            message: "Unmounting \(targetDisk.deviceNode)."
        )

        for _ in 0..<8 {
            let stillMounted = (try? await diskService.mountedPartitions(forWholeDisk: targetDisk.identifier)
                .contains { $0.mountPoint != nil }) ?? false
            if !stillMounted {
                return
            }
            try await Task.sleep(for: .milliseconds(250))
        }
    }

    private func requestRemovableVolumeAccessIfNeeded(_ targetDisk: ExternalDisk) async throws {
        let partitions = (try? await diskService.mountedPartitions(forWholeDisk: targetDisk.identifier)) ?? []
        for partition in partitions {
            guard let mountPoint = partition.mountPoint else {
                continue
            }

            do {
                _ = try FileManager.default.contentsOfDirectory(
                    at: mountPoint,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                )
            } catch {
                throw DriveImagingServiceError.removableVolumePermissionDenied(
                    "macOS denied FlashKit access to the removable volume at \(mountPoint.path). Allow FlashKit removable-volume access, then try writing again."
                )
            }
        }
    }

    private struct StagedSource: Sendable {
        let url: URL
        let cleanup: @Sendable () -> Void
    }

    private func stageSourceForPrivilegedRead(
        _ sourceURL: URL,
        progress: @escaping @Sendable (Int64, Int64, String) async -> Void
    ) async throws -> StagedSource {
        let fileManager = FileManager.default
        let stagingRoot = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("FlashKitRawSource-\(UUID().uuidString)", isDirectory: true)
        let stagedURL = stagingRoot.appendingPathComponent(sourceURL.lastPathComponent)

        do {
            try fileManager.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
            try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stagingRoot.path())

            do {
                try fileManager.linkItem(at: sourceURL, to: stagedURL)
                try? fileManager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: stagedURL.path())
                return StagedSource(url: stagedURL, cleanup: { try? FileManager.default.removeItem(at: stagingRoot) })
            } catch {
                let size = Int64(try sourceURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
                try await copySourceForPrivilegedRead(
                    from: sourceURL,
                    to: stagedURL,
                    totalBytes: size,
                    progress: progress
                )
                try? fileManager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: stagedURL.path())
                return StagedSource(url: stagedURL, cleanup: { try? FileManager.default.removeItem(at: stagingRoot) })
            }
        } catch {
            try? fileManager.removeItem(at: stagingRoot)
            throw DriveImagingServiceError.sourceStagingFailed(
                "FlashKit could not stage the source image for privileged writing: \(error.localizedDescription)"
            )
        }
    }

    private func copySourceForPrivilegedRead(
        from sourceURL: URL,
        to stagedURL: URL,
        totalBytes: Int64,
        progress: @escaping @Sendable (Int64, Int64, String) async -> Void
    ) async throws {
        let sourceHandle = try FileHandle(forReadingFrom: sourceURL)
        FileManager.default.createFile(atPath: stagedURL.path(), contents: nil)
        let destinationHandle = try FileHandle(forWritingTo: stagedURL)
        defer {
            try? sourceHandle.close()
            try? destinationHandle.close()
        }

        var copiedBytes: Int64 = 0
        while true {
            try Task.checkCancellation()
            let chunk = try sourceHandle.read(upToCount: 4 * 1024 * 1024) ?? Data()
            if chunk.isEmpty {
                break
            }
            try destinationHandle.write(contentsOf: chunk)
            copiedBytes += Int64(chunk.count)
            await progress(copiedBytes, totalBytes, "Copying source image into temporary write staging.")
        }
    }
}
