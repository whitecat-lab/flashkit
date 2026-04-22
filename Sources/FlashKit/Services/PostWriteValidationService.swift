import Foundation
import OSLog

struct PostWriteValidationService: Sendable {
    private let logger = Logger(subsystem: "FlashKit", category: "PostWriteValidation")
    private let bootValidationService = BootValidationService()
    private let vendorRegistry: VendorValidationRegistry
    private let snapshotProvider: @Sendable (ExternalDisk) async throws -> MediaTargetSnapshot

    init(
        vendorRegistry: VendorValidationRegistry = VendorValidationRegistry(),
        snapshotProvider: @escaping @Sendable (ExternalDisk) async throws -> MediaTargetSnapshot = PostWriteValidationService.defaultSnapshot
    ) {
        self.vendorRegistry = vendorRegistry
        self.snapshotProvider = snapshotProvider
    }

    func assertValid(
        sourceProfile: SourceImageProfile,
        targetDisk: ExternalDisk,
        plan: WritePlan,
        executionMetadata: BackendWriteExecutionMetadata?,
        destinationRoot: URL?,
        ntfsDestinationPartition: DiskPartition?,
        customization: CustomizationProfile,
        toolchain: ToolchainStatus,
        ntfsPopulateService: NTFSPopulateService
    ) async throws {
        let result = await validateWrittenMedia(
            sourceProfile: sourceProfile,
            targetDisk: targetDisk,
            plan: plan,
            executionMetadata: executionMetadata,
            destinationRoot: destinationRoot,
            ntfsDestinationPartition: ntfsDestinationPartition,
            customization: customization,
            toolchain: toolchain,
            ntfsPopulateService: ntfsPopulateService
        )

        guard result.passed else {
            throw MediaValidationServiceError.failed(result)
        }
    }

    func validateWrittenMedia(
        sourceProfile: SourceImageProfile,
        targetDisk: ExternalDisk,
        plan: WritePlan,
        executionMetadata: BackendWriteExecutionMetadata?,
        destinationRoot: URL?,
        ntfsDestinationPartition: DiskPartition?,
        customization: CustomizationProfile,
        toolchain: ToolchainStatus,
        ntfsPopulateService: NTFSPopulateService
    ) async -> MediaValidationResult {
        let matchedProfile = sourceProfile.classification?.matchedVendorProfile
        let profileVariant = sourceProfile.classification?.matchedProfile?.variant

        logger.info(
            "validation start image=\(sourceProfile.displayName, privacy: .public) vendor=\(matchedProfile?.rawValue ?? "none", privacy: .public) strategy=\(executionMetadata?.selectedWriteStrategy.rawValue ?? "none", privacy: .public) target=\(targetDisk.deviceNode, privacy: .public)"
        )

        let snapshot: MediaTargetSnapshot
        do {
            snapshot = try await snapshotProvider(targetDisk)
        } catch {
            let check = MediaValidationCheck(
                identifier: "snapshot",
                title: "Target snapshot",
                status: .failed,
                detail: "The backend could not inspect the written target for structural validation: \(error.localizedDescription)"
            )
            let result = MediaValidationResult(
                passed: false,
                confidence: 0.10,
                depth: .quick,
                checksPerformed: [check],
                warnings: [],
                profileNotes: [],
                structurallyPlausibleButNotGuaranteedBootable: false,
                matchedProfile: matchedProfile,
                profileVariant: profileVariant,
                failureReason: check.detail
            )
            log(result, sourceProfile: sourceProfile, targetDisk: targetDisk)
            return result
        }

        let context = MediaValidationContext(
            sourceProfile: sourceProfile,
            targetDisk: targetDisk,
            plan: plan,
            executionMetadata: executionMetadata,
            destinationRoot: destinationRoot,
            ntfsDestinationPartition: ntfsDestinationPartition,
            customization: customization,
            toolchain: toolchain,
            snapshot: snapshot
        )

        var builder = MediaValidationResultBuilder(matchedProfile: matchedProfile, profileVariant: profileVariant)
        await runGenericChecks(into: &builder, context: context)
        await runWorkflowChecks(into: &builder, context: context, ntfsPopulateService: ntfsPopulateService)
        await runVendorChecks(into: &builder, context: context)

        let result = builder.build()
        log(result, sourceProfile: sourceProfile, targetDisk: targetDisk)
        return result
    }

    private func runGenericChecks(
        into builder: inout MediaValidationResultBuilder,
        context: MediaValidationContext
    ) async {
        let snapshot = context.snapshot

        if snapshot.partitionTableReadable {
            builder.pass(
                "partition-table",
                title: "Readable partition layout",
                detail: "The backend could read \(snapshot.partitions.count) partition(s) from the written target."
            )
        } else if context.plan.partitionScheme == .superFloppy {
            builder.warn(
                "partition-table",
                title: "Readable partition layout",
                detail: "The written target did not expose a readable partition table. This can still be structurally plausible for super-floppy-style raw images."
            )
        } else {
            builder.fail(
                "partition-table",
                title: "Readable partition layout",
                detail: "The written target did not expose a readable partition table."
            )
        }

        if context.plan.partitionLayouts.isEmpty {
            builder.skip(
                "expected-partitions",
                title: "Expected partitions",
                detail: "This backend write path does not declare a fixed partition layout."
            )
        } else if snapshot.partitions.count >= context.plan.partitionLayouts.count {
            builder.pass(
                "expected-partitions",
                title: "Expected partitions",
                detail: "The target exposed at least the expected \(context.plan.partitionLayouts.count) partition(s)."
            )
        } else {
            builder.fail(
                "expected-partitions",
                title: "Expected partitions",
                detail: "The target exposed \(snapshot.partitions.count) partition(s), fewer than the expected \(context.plan.partitionLayouts.count)."
            )
        }

        await validateFilesystemLayout(into: &builder, context: context)
        validateGenericBootArtifacts(into: &builder, context: context)
    }

    private func validateFilesystemLayout(
        into builder: inout MediaValidationResultBuilder,
        context: MediaValidationContext
    ) async {
        guard let primaryFilesystem = context.plan.primaryFilesystem else {
            builder.skip(
                "filesystem-layout",
                title: "Filesystem/layout signature",
                detail: "This backend write path does not expect a specific mounted filesystem signature."
            )
            return
        }

        guard let primaryPartition = context.snapshot.partitions.first else {
            builder.warn(
                "filesystem-layout",
                title: "Filesystem/layout signature",
                detail: "No readable primary partition was available to validate the expected \(primaryFilesystem.rawValue.uppercased()) layout."
            )
            return
        }

        let description = "\(primaryPartition.filesystemDescription) \(primaryPartition.contentDescription)".lowercased()
        switch primaryFilesystem {
        case .fat32, .fat:
            if description.contains("fat") || description.contains("ms-dos") || description.contains("msdos") {
                builder.pass(
                    "filesystem-layout",
                    title: "Filesystem/layout signature",
                    detail: "The primary partition reports a FAT-family filesystem layout."
                )
            } else {
                builder.fail(
                    "filesystem-layout",
                    title: "Filesystem/layout signature",
                    detail: "The primary partition did not report the expected FAT-family filesystem layout."
                )
            }
        case .ntfs:
            if description.contains("ntfs") {
                builder.pass(
                    "filesystem-layout",
                    title: "Filesystem/layout signature",
                    detail: "The primary partition reports an NTFS layout."
                )
            } else {
                builder.warn(
                    "filesystem-layout",
                    title: "Filesystem/layout signature",
                    detail: "The primary partition did not report NTFS through macOS disk metadata, so the result is structurally plausible but not fully confirmed."
                )
            }
        default:
            builder.pass(
                "filesystem-layout",
                title: "Filesystem/layout signature",
                detail: "The primary partition reports a readable \(primaryFilesystem.rawValue.uppercased())-oriented layout signature."
            )
        }
    }

    private func validateGenericBootArtifacts(
        into builder: inout MediaValidationResultBuilder,
        context: MediaValidationContext
    ) {
        let roots = context.snapshot.mountedRoots
        let expectsEFI = context.sourceProfile.hasEFI
            || context.sourceProfile.isUEFIShellImage
            || [.proxmoxVE, .trueNAS, .opnSense, .pfSense].contains(context.sourceProfile.classification?.matchedVendorProfile)
        let expectsBootMarkers = context.sourceProfile.hasBIOS
            || context.sourceProfile.isLinuxBootImage
            || context.sourceProfile.isWindowsInstaller
            || [.proxmoxVE, .trueNAS, .opnSense, .pfSense].contains(context.sourceProfile.classification?.matchedVendorProfile)

        if expectsEFI {
            let efiCandidates = [
                "efi/boot/bootx64.efi",
                "efi/boot/bootaa64.efi",
                "efi/boot/grubx64.efi",
                "efi/boot/grubaa64.efi",
                "boot/loader.efi",
                "efi/boot/loader.efi",
            ]
            if roots.isEmpty {
                builder.warn(
                    "efi-boot-path",
                    title: "EFI boot path",
                    detail: "The target did not expose a mounted EFI filesystem on this Mac, so EFI boot paths could not be inspected."
                )
            } else if containsAny(of: efiCandidates, in: roots) {
                builder.pass(
                    "efi-boot-path",
                    title: "EFI boot path",
                    detail: "Found an expected EFI boot path on the written target."
                )
            } else {
                builder.fail(
                    "efi-boot-path",
                    title: "EFI boot path",
                    detail: "Missing the expected EFI boot paths on the written target."
                )
            }
        } else {
            builder.skip(
                "efi-boot-path",
                title: "EFI boot path",
                detail: "This media flow does not require EFI boot files."
            )
        }

        if expectsBootMarkers {
            let markerCandidates = [
                "boot/grub/grub.cfg",
                "grub/grub.cfg",
                "isolinux/isolinux.cfg",
                "syslinux/syslinux.cfg",
                "boot/defaults/loader.conf",
                "boot/loader.conf",
                "boot/bcd",
                "bootmgr",
            ]
            if roots.isEmpty {
                builder.warn(
                    "bootloader-markers",
                    title: "Bootloader/config markers",
                    detail: "The target did not expose mounted filesystems for a deeper bootloader/config inspection."
                )
            } else if containsAny(of: markerCandidates, in: roots) {
                builder.pass(
                    "bootloader-markers",
                    title: "Bootloader/config markers",
                    detail: "Found recognizable bootloader/config markers on the written target."
                )
            } else {
                builder.fail(
                    "bootloader-markers",
                    title: "Bootloader/config markers",
                    detail: "No recognizable bootloader/config markers were found on the written target."
                )
            }
        } else {
            builder.skip(
                "bootloader-markers",
                title: "Bootloader/config markers",
                detail: "This media flow does not require additional bootloader/config marker checks."
            )
        }
    }

    private func runWorkflowChecks(
        into builder: inout MediaValidationResultBuilder,
        context: MediaValidationContext,
        ntfsPopulateService: NTFSPopulateService
    ) async {
        let boots = bootValidationService

        switch context.plan.mediaMode {
        case .windowsInstaller:
            do {
                try await boots.validateWindowsMedia(
                    sourceProfile: context.sourceProfile,
                    destinationRoot: context.destinationRoot,
                    ntfsDestinationPartition: context.ntfsDestinationPartition,
                    targetDisk: context.targetDisk,
                    plan: context.plan,
                    customization: context.customization,
                    toolchain: context.toolchain,
                    ntfsPopulateService: ntfsPopulateService
                )
                builder.pass("workflow-windows", title: "Windows structural validation", detail: "Validated the expected Windows installer boot artifacts.")
            } catch {
                builder.fail("workflow-windows", title: "Windows structural validation", detail: error.localizedDescription)
            }
        case .directImage:
            switch context.plan.payloadMode {
            case .freeDOS:
                guard let destinationRoot = context.destinationRoot,
                      let primaryPartition = context.ntfsDestinationPartition ?? partition(from: context.snapshot, matchingMountPoint: destinationRoot) ?? context.snapshot.partitions.first.map(toDiskPartition) else {
                    builder.fail("workflow-freedos", title: "FreeDOS structural validation", detail: "The backend could not resolve the FreeDOS destination partition for validation.")
                    return
                }
                do {
                    try await boots.validateFreeDOSMedia(destinationRoot: destinationRoot, primaryPartition: primaryPartition)
                    builder.pass("workflow-freedos", title: "FreeDOS structural validation", detail: "Validated the expected FreeDOS boot sector and system files.")
                } catch {
                    builder.fail("workflow-freedos", title: "FreeDOS structural validation", detail: error.localizedDescription)
                }
            case .linuxPersistenceCasper, .linuxPersistenceDebian:
                guard let destinationRoot = context.destinationRoot,
                      let primaryPartition = partition(from: context.snapshot, matchingMountPoint: destinationRoot) ?? context.snapshot.partitions.first.map(toDiskPartition) else {
                    builder.fail("workflow-linux-persistence", title: "Linux persistence validation", detail: "The backend could not resolve the Linux persistence boot partition for validation.")
                    return
                }
                do {
                    try await boots.validateLinuxPersistenceMedia(
                        destinationRoot: destinationRoot,
                        targetDisk: context.targetDisk,
                        persistenceFlavor: context.sourceProfile.persistenceFlavor,
                        primaryPartition: primaryPartition
                    )
                    builder.pass("workflow-linux-persistence", title: "Linux persistence validation", detail: "Validated the Linux persistence partition and boot configuration.")
                } catch {
                    builder.fail("workflow-linux-persistence", title: "Linux persistence validation", detail: error.localizedDescription)
                }
            case .fat32Extract:
                if let destinationRoot = context.destinationRoot,
                   let primaryPartition = partition(from: context.snapshot, matchingMountPoint: destinationRoot) ?? context.snapshot.partitions.first.map(toDiskPartition) {
                    do {
                        if context.sourceProfile.isUEFIShellImage {
                            try await boots.validateUEFIShellMedia(destinationRoot: destinationRoot, primaryPartition: primaryPartition)
                        } else if context.sourceProfile.isLinuxBootImage {
                            try await boots.validateLinuxMedia(destinationRoot: destinationRoot, sourceProfile: context.sourceProfile, primaryPartition: primaryPartition)
                        }
                        builder.pass("workflow-fat32-extract", title: "Extracted-media validation", detail: "Validated the expected extracted boot-media structure.")
                    } catch {
                        builder.fail("workflow-fat32-extract", title: "Extracted-media validation", detail: error.localizedDescription)
                    }
                }
            default:
                builder.skip("workflow-direct", title: "Workflow-specific validation", detail: "No additional workflow-specific validation was required beyond the generic structural checks.")
            }
        case .driveRestore:
            builder.skip("workflow-drive-restore", title: "Workflow-specific validation", detail: "Drive restore relies on raw verification plus generic structural validation.")
        case .driveCapture:
            builder.skip("workflow-drive-capture", title: "Workflow-specific validation", detail: "Capture workflows do not run post-write target validation.")
        }
    }

    private func runVendorChecks(
        into builder: inout MediaValidationResultBuilder,
        context: MediaValidationContext
    ) async {
        guard let validator = vendorRegistry.validator(for: context.sourceProfile.classification?.matchedVendorProfile) else {
            return
        }

        let outcome = await validator.validate(in: context)
        for check in outcome.checks {
            builder.record(check)
        }
        for warning in outcome.warnings {
            builder.addWarning(warning)
        }
        for note in outcome.notes {
            builder.addNote(note)
        }
        if outcome.structurallyPlausibleButNotGuaranteedBootable {
            builder.markPlausibleOnly()
        }
    }

    private func log(_ result: MediaValidationResult, sourceProfile: SourceImageProfile, targetDisk: ExternalDisk) {
        let checkSummary = result.checksPerformed
            .map { "\($0.identifier)=\($0.status.rawValue)" }
            .joined(separator: ",")

        if result.passed {
            logger.info(
                "validation finished image=\(sourceProfile.displayName, privacy: .public) target=\(targetDisk.deviceNode, privacy: .public) vendor=\(result.matchedProfile?.rawValue ?? "none", privacy: .public) passed=true confidence=\(String(format: "%.2f", result.confidence), privacy: .public) plausibleOnly=\(result.structurallyPlausibleButNotGuaranteedBootable, privacy: .public) checks=\(checkSummary, privacy: .public) warnings=\(result.warnings.joined(separator: " | "), privacy: .public)"
            )
        } else {
            logger.error(
                "validation finished image=\(sourceProfile.displayName, privacy: .public) target=\(targetDisk.deviceNode, privacy: .public) vendor=\(result.matchedProfile?.rawValue ?? "none", privacy: .public) passed=false confidence=\(String(format: "%.2f", result.confidence), privacy: .public) failure=\(result.failureReason ?? "unknown", privacy: .public) checks=\(checkSummary, privacy: .public) warnings=\(result.warnings.joined(separator: " | "), privacy: .public)"
            )
        }
    }

    private func partition(from snapshot: MediaTargetSnapshot, matchingMountPoint mountPoint: URL) -> DiskPartition? {
        snapshot.partitions.first(where: { $0.mountPoint?.standardizedFileURL == mountPoint.standardizedFileURL }).map(toDiskPartition)
    }

    private func toDiskPartition(_ snapshot: ValidationPartitionSnapshot) -> DiskPartition {
        DiskPartition(identifier: snapshot.identifier, deviceNode: snapshot.deviceNode, mountPoint: snapshot.mountPoint)
    }

    private func containsAny(of relativePaths: [String], in roots: [URL]) -> Bool {
        roots.contains { root in
            relativePaths.contains { relativePath in
                existingURL(in: root, relativePath: relativePath) != nil
            }
        }
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

    private static func defaultSnapshot(for targetDisk: ExternalDisk) async throws -> MediaTargetSnapshot {
        let runner = ProcessRunner()
        let diskService = DiskService()

        _ = try? await runner.run("/usr/sbin/diskutil", arguments: ["mountDisk", targetDisk.deviceNode])
        let partitions = try await diskService.mountedPartitions(forWholeDisk: targetDisk.identifier)
        var snapshots: [ValidationPartitionSnapshot] = []
        for partition in partitions {
            let info = try await diskService.diskInfo(for: partition.identifier)
            let filesystemDescription = [
                info["FilesystemName"] as? String,
                info["FilesystemType"] as? String,
            ]
                .compactMap { $0 }
                .joined(separator: " ")
            let contentDescription = info["Content"] as? String ?? ""
            snapshots.append(
                ValidationPartitionSnapshot(
                    identifier: partition.identifier,
                    deviceNode: partition.deviceNode,
                    mountPoint: partition.mountPoint,
                    filesystemDescription: filesystemDescription,
                    contentDescription: contentDescription
                )
            )
        }

        return MediaTargetSnapshot(
            wholeDiskIdentifier: targetDisk.identifier,
            deviceNode: targetDisk.deviceNode,
            partitionTableReadable: !snapshots.isEmpty,
            partitions: snapshots.sorted { $0.identifier < $1.identifier }
        )
    }
}

private struct MediaValidationResultBuilder {
    private(set) var checks: [MediaValidationCheck] = []
    private(set) var warnings: [String] = []
    private(set) var notes: [String] = []
    private(set) var plausibleOnly = false
    let matchedProfile: VendorProfileID?
    let profileVariant: String?

    init(matchedProfile: VendorProfileID?, profileVariant: String?) {
        self.matchedProfile = matchedProfile
        self.profileVariant = profileVariant
    }

    mutating func record(_ check: MediaValidationCheck) {
        checks.append(check)
        if check.status == .warning {
            warnings.append(check.detail)
            plausibleOnly = true
        }
        if check.status == .failed {
            plausibleOnly = false
        }
    }

    mutating func pass(_ identifier: String, title: String, detail: String) {
        record(.init(identifier: identifier, title: title, status: .passed, detail: detail))
    }

    mutating func warn(_ identifier: String, title: String, detail: String) {
        record(.init(identifier: identifier, title: title, status: .warning, detail: detail))
    }

    mutating func fail(_ identifier: String, title: String, detail: String) {
        record(.init(identifier: identifier, title: title, status: .failed, detail: detail))
    }

    mutating func skip(_ identifier: String, title: String, detail: String) {
        record(.init(identifier: identifier, title: title, status: .skipped, detail: detail))
    }

    mutating func addWarning(_ warning: String) {
        if !warnings.contains(warning) {
            warnings.append(warning)
        }
    }

    mutating func addNote(_ note: String) {
        if !notes.contains(note) {
            notes.append(note)
        }
    }

    mutating func markPlausibleOnly() {
        plausibleOnly = true
    }

    func build() -> MediaValidationResult {
        let failed = checks.contains { $0.status == .failed }
        let warningCount = checks.filter { $0.status == .warning }.count
        let skippedCount = checks.filter { $0.status == .skipped }.count
        let passedCount = checks.filter { $0.status == .passed }.count
        let confidence: Double
        if failed {
            confidence = max(0.20, min(0.55, 0.45 + (Double(passedCount) * 0.03) - (Double(warningCount) * 0.08)))
        } else {
            confidence = min(0.97, max(0.55, 0.65 + (Double(passedCount) * 0.04) - (Double(warningCount) * 0.05) - (Double(skippedCount) * 0.02)))
        }

        let failureReason = checks.first(where: { $0.status == .failed && $0.identifier.hasPrefix("vendor-") })?.detail
            ?? checks.first(where: { $0.status == .failed })?.detail
        let finalWarnings = Array(Set(warnings)).sorted()
        let finalNotes = Array(Set(notes)).sorted()
        let plausible = !failed && (plausibleOnly || warningCount > 0 || skippedCount > 0)
        let depth: MediaValidationDepth = checks.contains(where: { ["efi-boot-path", "bootloader-markers"].contains($0.identifier) && $0.status == .passed }) ? .full : .quick

        return MediaValidationResult(
            passed: !failed,
            confidence: confidence,
            depth: depth,
            checksPerformed: checks,
            warnings: finalWarnings,
            profileNotes: finalNotes,
            structurallyPlausibleButNotGuaranteedBootable: plausible,
            matchedProfile: matchedProfile,
            profileVariant: profileVariant,
            failureReason: failureReason
        )
    }
}
