import FlashKitHelperProtocol
import Foundation
import OSLog

enum WindowsInstallerServiceError: LocalizedError {
    case missingWimlib
    case missingInstallImage
    case missingBootAssets
    case unmountedDestination

    var errorDescription: String? {
        switch self {
        case .missingWimlib:
            return "wimlib-imagex is required for the selected Windows installer path."
        case .missingInstallImage:
            return "The Windows install image could not be found in the mounted source."
        case .missingBootAssets:
            return "Standalone WIM/ESD media requires a Windows setup boot-assets source."
        case .unmountedDestination:
            return "The destination volume did not mount after partitioning."
        }
    }
}

struct WindowsInstallerService {
    private let logger = Logger(subsystem: "FlashKit", category: "WindowsInstallerWrite")
    private let mounter = DiskImageMounter()
    private let runner = ProcessRunner()
    private let diskService = DiskService()
    private let partitioning = PartitioningService()
    private let patchService = WindowsInstallerPatchService()
    private let uefiNTFSService = UEFINTFSService()
    private let customizationService = WindowsCustomizationService()
    private let filesystemService = FilesystemService()
    private let verificationService = VerificationService()
    private let ntfsPopulateService = NTFSPopulateService()
    private let postWriteValidationService = PostWriteValidationService()
    private let countedCopyService = CountedFileCopyService()

    func createInstallerMedia(
        sourceProfile: SourceImageProfile,
        sourceURL: URL,
        targetDisk: ExternalDisk,
        plan: WritePlan,
        volumeLabel: String,
        options: WriteOptions,
        bootAssetsURL: URL?,
        toolchain: ToolchainStatus,
        executionMetadata: BackendWriteExecutionMetadata? = nil,
        progress: @escaping @Sendable (WriteSessionUpdate) async -> Void
    ) async throws {
        let initialSource = try await prepareSource(
            sourceProfile: sourceProfile,
            sourceURL: sourceURL,
            bootAssetsURL: bootAssetsURL
        )
        var runtimeExecutionMetadata = executionMetadata
        let stagedSource = try await stageInstallImageIfNeeded(
            sourceProfile: sourceProfile,
            preparedSource: initialSource,
            plan: plan,
            toolchain: toolchain,
            progress: progress
        )
        let preparedSource = stagedSource.preparedSource
        if let telemetry = stagedSource.workerTelemetry {
            runtimeExecutionMetadata = runtimeExecutionMetadata?.applying(workerTelemetry: telemetry)
        }
        var refreshedPrimaryPartition: DiskPartition?

        do {
            logger.info("phase=partitioning image=\(sourceProfile.displayName, privacy: .public) target=\(targetDisk.deviceNode, privacy: .public)")
            await progress(.init(phase: "Partitioning", message: "Preparing the target disk for \(plan.mediaMode.rawValue).", fractionCompleted: 0.08))
            let preparedTarget = try await partitioning.prepareInstallerTarget(plan: plan, targetDisk: targetDisk, volumeLabel: volumeLabel)
            await progress(
                .init(
                    phase: "Partitioning",
                    message: "Prepared the target partition layout.",
                    fractionCompleted: 0.12,
                    details: BackendActivityLogFormatter.partitionWriteLines(for: plan, volumeLabel: volumeLabel)
                )
            )

            if plan.usesUEFINTFSPath, let helperPartition = preparedTarget.helperPartition {
                await progress(.init(phase: "UEFI:NTFS", message: "Staging the UEFI helper partition.", fractionCompleted: 0.14))
                logger.info("phase=uefi-ntfs image=\(sourceProfile.displayName, privacy: .public) target=\(targetDisk.deviceNode, privacy: .public)")
                let helperBridge = WorkerProgressBridge(
                    phase: "UEFI:NTFS",
                    baseMessage: "Staging the UEFI helper partition.",
                    range: BackendPhaseRange(start: 0.14, end: 0.22),
                    progress: progress
                )
                try await uefiNTFSService.stageHelperPartition(
                    helperPartition,
                    toolchain: toolchain,
                    eventHandler: { event in
                        await helperBridge.handleWorkerEvent(event)
                    }
                )
                if let telemetry = await helperBridge.snapshotTelemetry() {
                    runtimeExecutionMetadata = runtimeExecutionMetadata?.applying(workerTelemetry: telemetry)
                }
            }

            var destinationRoot: URL?
            switch plan.payloadMode {
            case .ntfsUefiNtfs:
                try await filesystemService.formatPartition(
                    partition: preparedTarget.primaryPartition,
                    filesystem: .ntfs,
                    volumeName: volumeLabel,
                    toolchain: toolchain
                )
                refreshedPrimaryPartition = try await refreshedPartition(preparedTarget.primaryPartition, on: targetDisk)
            case .genericOversizedEfi:
                try await filesystemService.formatPartition(
                    partition: preparedTarget.primaryPartition,
                    filesystem: .exfat,
                    volumeName: volumeLabel,
                    toolchain: toolchain
                )
                refreshedPrimaryPartition = try await mountedPayloadPartition(
                    preparedTarget.primaryPartition,
                    on: targetDisk,
                    filesystem: .exfat
                )
                guard let mountPoint = refreshedPrimaryPartition?.mountPoint else {
                    throw WindowsInstallerServiceError.unmountedDestination
                }
                destinationRoot = mountPoint
            case .fat32SplitWim, .fat32Extract:
                refreshedPrimaryPartition = try await mountedPayloadPartition(
                    preparedTarget.primaryPartition,
                    on: targetDisk,
                    filesystem: .fat32
                )
                guard let mountPoint = refreshedPrimaryPartition?.mountPoint else {
                    throw WindowsInstallerServiceError.unmountedDestination
                }
                destinationRoot = mountPoint
            case .directRaw, .freeDOS, .linuxPersistenceCasper, .linuxPersistenceDebian:
                throw WindowsInstallerServiceError.unmountedDestination
            }

            let skippedPath = plan.payloadMode == .fat32SplitWim ? sourceProfile.windows?.installImageRelativePath : nil
            let primaryPartition = refreshedPrimaryPartition ?? preparedTarget.primaryPartition
            if plan.payloadMode == .ntfsUefiNtfs {
                logger.info("phase=copying image=\(sourceProfile.displayName, privacy: .public) target=\(targetDisk.deviceNode, privacy: .public) mode=ntfs")
                await progress(.init(phase: "Copying files", message: "Populating the NTFS installer payload.", fractionCompleted: 0.22))
                let ntfsBridge = WorkerProgressBridge(
                    phase: "Copying files",
                    baseMessage: "Populating the NTFS installer payload.",
                    range: BackendPhaseRange(start: 0.22, end: 0.74),
                    progress: progress
                )
                try await ntfsPopulateService.copyContents(
                    from: preparedSource.rootURL,
                    to: primaryPartition,
                    skippingRelativePath: skippedPath,
                    toolchain: toolchain,
                    eventHandler: { event in
                        await ntfsBridge.handleWorkerEvent(event)
                    }
                )
                if let telemetry = await ntfsBridge.snapshotTelemetry() {
                    runtimeExecutionMetadata = runtimeExecutionMetadata?.applying(workerTelemetry: telemetry)
                }
            } else if let destinationRoot {
                logger.info("phase=copying image=\(sourceProfile.displayName, privacy: .public) target=\(targetDisk.deviceNode, privacy: .public) mode=filesystem")
                await progress(.init(phase: "Copying files", message: "Copying installer files to \(destinationRoot.lastPathComponent).", fractionCompleted: 0.22))
                let fileCopyBridge = WorkerProgressBridge(
                    phase: "Copying files",
                    baseMessage: "Copying installer files to \(destinationRoot.lastPathComponent).",
                    range: BackendPhaseRange(start: 0.22, end: 0.74),
                    progress: progress
                )
                try await copyContents(from: preparedSource.rootURL, to: destinationRoot, skippingRelativePaths: skippedPath.map { [$0] } ?? []) { completedBytes, totalBytes, file in
                    await fileCopyBridge.reportBytes(
                        completedBytes: completedBytes,
                        totalBytes: totalBytes,
                        message: file,
                        rateBytesPerSecond: nil
                    )
                }
            }

            if plan.payloadMode == .fat32SplitWim {
                guard
                    let installPath = sourceProfile.windows?.installImageRelativePath,
                    let destinationRoot
                else {
                    throw WindowsInstallerServiceError.unmountedDestination
                }

                await progress(.init(phase: "Copying prepared image", message: "Copying the prepared Windows install image.", fractionCompleted: 0.74))
                logger.info("phase=copying-prepared-wim image=\(sourceProfile.displayName, privacy: .public) target=\(targetDisk.deviceNode, privacy: .public)")
                let splitBridge = WorkerProgressBridge(
                    phase: "Copying prepared image",
                    baseMessage: "Copying the prepared Windows install image.",
                    range: BackendPhaseRange(start: 0.74, end: 0.82),
                    progress: progress
                )
                try await copyPreparedSplitInstallImage(
                    preparedSource: preparedSource,
                    installRelativePath: installPath,
                    destinationRoot: destinationRoot
                ) { completedBytes, totalBytes, file in
                    await splitBridge.reportBytes(
                        completedBytes: completedBytes,
                        totalBytes: totalBytes,
                        message: file,
                        rateBytesPerSecond: nil
                    )
                }
                if let telemetry = await splitBridge.snapshotTelemetry() {
                    runtimeExecutionMetadata = runtimeExecutionMetadata?.applying(workerTelemetry: telemetry)
                }
            }

            await progress(.init(phase: "Patching", message: "Applying Windows compatibility patches.", fractionCompleted: 0.82))
            logger.info("phase=patching image=\(sourceProfile.displayName, privacy: .public) target=\(targetDisk.deviceNode, privacy: .public)")
            try await patchService.applyRequiredPatches(
                profile: sourceProfile,
                sourceRoot: preparedSource.rootURL,
                destinationRoot: destinationRoot,
                ntfsDestinationPartition: plan.payloadMode == .ntfsUefiNtfs ? primaryPartition : nil,
                plan: plan,
                customization: options.customizationProfile,
                toolchain: toolchain,
                ntfsPopulateService: ntfsPopulateService
            )

            _ = try await customizationService.applyCustomization(
                profile: sourceProfile,
                destinationRoot: destinationRoot,
                ntfsDestinationPartition: plan.payloadMode == .ntfsUefiNtfs ? primaryPartition : nil,
                customization: options.customizationProfile,
                toolchain: toolchain,
                ntfsPopulateService: ntfsPopulateService
            )

            if plan.postWriteFixups.contains(.ntfsFinalize), let ntfsfix = toolchain.path(for: .ntfsfix) {
                await progress(.init(phase: "Finalizing NTFS", message: "Running the NTFS finalization pass.", fractionCompleted: 0.88))
                logger.info("phase=finalizing-ntfs image=\(sourceProfile.displayName, privacy: .public) target=\(targetDisk.deviceNode, privacy: .public)")
                try await filesystemService.finalizeNTFSPartition(
                    partition: primaryPartition,
                    ntfsfixPath: ntfsfix
                )
            }

            await progress(.init(phase: "Verifying", message: "Verifying the copied Windows installer media.", fractionCompleted: 0.92))
            logger.info("phase=verifying image=\(sourceProfile.displayName, privacy: .public) target=\(targetDisk.deviceNode, privacy: .public)")
            if plan.payloadMode == .ntfsUefiNtfs {
                try await verificationService.verifyWindowsInstallerOnNTFS(
                    sourceRoot: preparedSource.rootURL,
                    destinationPartition: primaryPartition,
                    profile: sourceProfile,
                    plan: plan,
                    customization: options.customizationProfile,
                    toolchain: toolchain,
                    ntfsPopulateService: ntfsPopulateService
                )
            } else if let destinationRoot {
                try await verificationService.verifyWindowsInstaller(
                    sourceRoot: preparedSource.rootURL,
                    destinationRoot: destinationRoot,
                    profile: sourceProfile,
                    plan: plan,
                    customization: options.customizationProfile
                )
            }

            logger.info("phase=validating image=\(sourceProfile.displayName, privacy: .public) target=\(targetDisk.deviceNode, privacy: .public)")
            let validationResult = await postWriteValidationService.validateWrittenMedia(
                sourceProfile: sourceProfile,
                targetDisk: targetDisk,
                plan: plan,
                executionMetadata: runtimeExecutionMetadata,
                destinationRoot: destinationRoot,
                ntfsDestinationPartition: plan.payloadMode == .ntfsUefiNtfs ? primaryPartition : nil,
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

            await filesystemService.sync()

            if options.ejectWhenFinished {
                await progress(.init(phase: "Ejecting", message: "Ejecting the installer USB.", fractionCompleted: 0.98))
                logger.info("phase=ejecting image=\(sourceProfile.displayName, privacy: .public) target=\(targetDisk.deviceNode, privacy: .public)")
                _ = try? await runner.run("/usr/sbin/diskutil", arguments: ["eject", targetDisk.deviceNode])
            }

            logger.info("phase=finished image=\(sourceProfile.displayName, privacy: .public) target=\(targetDisk.deviceNode, privacy: .public)")
            await progress(.init(phase: "Finished", message: "Windows installer media is ready.", fractionCompleted: 1.0))
            try await preparedSource.cleanup(using: mounter)
        } catch {
            logger.error("phase=failed image=\(sourceProfile.displayName, privacy: .public) target=\(targetDisk.deviceNode, privacy: .public) reason=\(error.localizedDescription, privacy: .public)")
            try? await preparedSource.cleanup(using: mounter)
            throw error
        }
    }

    private func refreshedPartition(_ partition: DiskPartition, on targetDisk: ExternalDisk) async throws -> DiskPartition {
        let partitions = try await diskService.mountedPartitions(forWholeDisk: targetDisk.identifier)
        return partitions.first(where: { $0.identifier == partition.identifier }) ?? partition
    }

    private func mountedPayloadPartition(
        _ partition: DiskPartition,
        on targetDisk: ExternalDisk,
        filesystem: FilesystemType
    ) async throws -> DiskPartition {
        var refreshed = try await diskService.firstPartition(afterFormatting: targetDisk.identifier, matching: filesystem)
        if refreshed.identifier != partition.identifier {
            refreshed = try await refreshedPartition(partition, on: targetDisk)
        }

        guard refreshed.mountPoint != nil else {
            let mountedURL = try await diskService.mountedVolumeURL(forWholeDisk: targetDisk.identifier)
            return DiskPartition(
                identifier: refreshed.identifier,
                deviceNode: refreshed.deviceNode,
                mountPoint: mountedURL
            )
        }

        return refreshed
    }

    private func swmPath(for relativePath: String) -> String {
        let base = (relativePath as NSString).deletingPathExtension
        return "\(base).swm"
    }

    private func copyContents(
        from sourceRoot: URL,
        to destinationRoot: URL,
        skippingRelativePaths: [String],
        progress: @escaping @Sendable (Int64, Int64, String) async -> Void
    ) async throws {
        let manifest = try countedCopyService.manifest(from: sourceRoot, skippingRelativePaths: skippingRelativePaths)
        try await countedCopyService.copyManifest(manifest, to: destinationRoot, progress: progress)
    }

    private func existingURL(in root: URL, relativePath: String) -> URL? {
        let fileManager = FileManager.default
        var current = root

        for component in relativePath.split(separator: "/").map(String.init) {
            guard let childName = try? fileManager.contentsOfDirectory(atPath: current.path()).first(where: { $0.caseInsensitiveCompare(component) == .orderedSame }) else {
                return nil
            }
            current.append(path: childName)
        }

        return current
    }

    private func prepareSource(
        sourceProfile: SourceImageProfile,
        sourceURL: URL,
        bootAssetsURL: URL?
    ) async throws -> PreparedInstallerSource {
        if sourceProfile.requiresBootAssetsSource {
            guard let bootAssetsURL else {
                throw WindowsInstallerServiceError.missingBootAssets
            }
            return try await rebuildStandaloneInstallerSource(
                sourceProfile: sourceProfile,
                standaloneInstallURL: sourceURL,
                bootAssetsURL: bootAssetsURL
            )
        }

        let mounted = try await mounter.mountImage(at: sourceURL)
        return PreparedInstallerSource(rootURL: mounted.mountPoint, mountedImage: mounted, temporaryRoot: nil, splitStagingRoot: nil)
    }

    private func rebuildStandaloneInstallerSource(
        sourceProfile: SourceImageProfile,
        standaloneInstallURL: URL,
        bootAssetsURL: URL
    ) async throws -> PreparedInstallerSource {
        let temporaryRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("FlashKit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)

        let bootAssetsIsDirectory = (try? bootAssetsURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        let mountedBootAssets = bootAssetsIsDirectory ? nil : try await mounter.mountImage(at: bootAssetsURL)
        let bootAssetsRoot = mountedBootAssets?.mountPoint ?? bootAssetsURL

        do {
            try await copyContents(
                from: bootAssetsRoot,
                to: temporaryRoot,
                skippingRelativePaths: ["sources/install.wim", "sources/install.esd"]
            ) { _, _, _ in
            }

            let installDestination = temporaryRoot.appending(path: sourceProfile.windows?.installImageRelativePath ?? "sources/install.wim")
            try FileManager.default.createDirectory(at: installDestination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: installDestination.path()) {
                try FileManager.default.removeItem(at: installDestination)
            }
            try FileManager.default.copyItem(at: standaloneInstallURL, to: installDestination)

            return PreparedInstallerSource(rootURL: temporaryRoot, mountedImage: mountedBootAssets, temporaryRoot: temporaryRoot, splitStagingRoot: nil)
        } catch {
            if let mountedBootAssets {
                try? await mounter.detach(mountedBootAssets)
            }
            try? FileManager.default.removeItem(at: temporaryRoot)
            throw error
        }
    }

    private func stageInstallImageIfNeeded(
        sourceProfile: SourceImageProfile,
        preparedSource: PreparedInstallerSource,
        plan: WritePlan,
        toolchain: ToolchainStatus,
        progress: @escaping @Sendable (WriteSessionUpdate) async -> Void
    ) async throws -> (preparedSource: PreparedInstallerSource, workerTelemetry: BackendWorkerRuntimeTelemetry?) {
        guard plan.payloadMode == .fat32SplitWim else {
            return (preparedSource, nil)
        }

        guard sourceProfile.windows?.requiresWIMSplit == true else {
            return (preparedSource, nil)
        }

        guard let wimlib = toolchain.path(for: .wimlibImagex) else {
            throw WindowsInstallerServiceError.missingWimlib
        }

        guard
            let installPath = sourceProfile.windows?.installImageRelativePath,
            let installURL = existingURL(in: preparedSource.rootURL, relativePath: installPath)
        else {
            throw WindowsInstallerServiceError.missingInstallImage
        }

        let installSize = Int64((try? installURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        guard installSize > SourceImageProfile.fat32MaximumFileSize else {
            return (preparedSource, nil)
        }

        let fileManager = FileManager.default
        let stagingRoot: URL
        if let splitStagingRoot = preparedSource.splitStagingRoot {
            stagingRoot = splitStagingRoot
        } else if let temporaryRoot = preparedSource.temporaryRoot {
            stagingRoot = temporaryRoot.appendingPathComponent(".split-staging", isDirectory: true)
        } else {
            stagingRoot = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("FlashKit-\(UUID().uuidString)", isDirectory: true)
        }

        if fileManager.fileExists(atPath: stagingRoot.path()) {
            try? fileManager.removeItem(at: stagingRoot)
        }
        try fileManager.createDirectory(at: stagingRoot, withIntermediateDirectories: true)

        let stagedInstallURL = stagingRoot.appending(path: swmPath(for: installPath))
        try fileManager.createDirectory(at: stagedInstallURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        await progress(.init(phase: "Preparing image", message: "Splitting the Windows install image before writing.", fractionCompleted: 0.06))
        logger.info("phase=staging-split-wim image=\(sourceProfile.displayName, privacy: .public)")
        let totalBytes = installSize
        let splitBridge = WorkerProgressBridge(
            phase: "Preparing image",
            baseMessage: "Splitting the Windows install image before writing.",
            range: BackendPhaseRange(start: 0.06, end: 0.18),
            progress: progress
        )

        let arguments = ["split", installURL.path(), stagedInstallURL.path(), "4094"]
        let monitorTask = Task {
            var lastBytes: Int64 = -1
            while !Task.isCancelled {
                let currentBytes = directorySize(at: stagingRoot)
                if currentBytes != lastBytes {
                    await splitBridge.reportBytes(
                        completedBytes: currentBytes,
                        totalBytes: totalBytes,
                        message: "Splitting the Windows install image before writing.",
                        rateBytesPerSecond: nil
                    )
                    lastBytes = currentBytes
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        defer {
            monitorTask.cancel()
        }

        _ = try await runner.run(
            wimlib,
            arguments: arguments,
            onStart: { processID in
                await splitBridge.emitLocalWorkerLines(
                    processID: processID,
                    command: [wimlib] + arguments,
                    mode: "local-subprocess"
                )
            }
        )
        await splitBridge.reportBytes(
            completedBytes: directorySize(at: stagingRoot),
            totalBytes: totalBytes,
            message: "Splitting the Windows install image before writing.",
            rateBytesPerSecond: nil
        )

        return (
            preparedSource.withSplitStagingRoot(stagingRoot),
            await splitBridge.snapshotTelemetry()
        )
    }

    private func copyPreparedSplitInstallImage(
        preparedSource: PreparedInstallerSource,
        installRelativePath: String,
        destinationRoot: URL,
        progress: @escaping @Sendable (Int64, Int64, String) async -> Void
    ) async throws {
        guard let splitStagingRoot = preparedSource.splitStagingRoot else {
            throw WindowsInstallerServiceError.missingInstallImage
        }

        let manifest = try countedCopyService.manifest(
            from: try stagedSplitInstallFiles(in: splitStagingRoot, relativeInstallPath: installRelativePath),
            relativeTo: splitStagingRoot
        )
        try await countedCopyService.copyManifest(manifest, to: destinationRoot, progress: progress)
    }

    func stagedSplitInstallFiles(in splitStagingRoot: URL, relativeInstallPath: String) throws -> [URL] {
        let splitDirectory = splitStagingRoot.appendingPathComponent((relativeInstallPath as NSString).deletingLastPathComponent, isDirectory: true)
        let splitBaseName = ((relativeInstallPath as NSString).deletingPathExtension as NSString).lastPathComponent.lowercased()
        let fileManager = FileManager.default
        let candidates = try fileManager.contentsOfDirectory(at: splitDirectory, includingPropertiesForKeys: nil)
        let matches = candidates.filter { url in
            let lowercased = url.lastPathComponent.lowercased()
            return lowercased.hasPrefix(splitBaseName) && lowercased.hasSuffix(".swm")
        }.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

        guard !matches.isEmpty else {
            throw WindowsInstallerServiceError.missingInstallImage
        }

        return matches
    }

    private func directorySize(at root: URL) -> Int64 {
        let fileManager = FileManager.default
        let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles])
        var total: Int64 = 0

        while let item = enumerator?.nextObject() as? URL {
            total += Int64((try? item.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }

        return total
    }
}

private struct PreparedInstallerSource {
    let rootURL: URL
    let mountedImage: MountedDiskImage?
    let temporaryRoot: URL?
    let splitStagingRoot: URL?

    func cleanup(using mounter: DiskImageMounter) async throws {
        if let mountedImage {
            try? await mounter.detach(mountedImage)
        }
        if let splitStagingRoot, splitStagingRoot != temporaryRoot {
            try? FileManager.default.removeItem(at: splitStagingRoot)
        }
        if let temporaryRoot {
            try? FileManager.default.removeItem(at: temporaryRoot)
        }
    }

    func withSplitStagingRoot(_ splitStagingRoot: URL) -> PreparedInstallerSource {
        PreparedInstallerSource(
            rootURL: rootURL,
            mountedImage: mountedImage,
            temporaryRoot: temporaryRoot,
            splitStagingRoot: splitStagingRoot
        )
    }
}
