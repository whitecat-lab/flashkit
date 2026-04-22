import Foundation
import OSLog

enum BootableUtilityServiceError: LocalizedError {
    case sourceUnavailable
    case destinationUnavailable
    case missingHelper(HelperTool)

    var errorDescription: String? {
        switch self {
        case .sourceUnavailable:
            return "The selected source could not be opened for extracted-media writing."
        case .destinationUnavailable:
            return "The destination payload partition did not mount after preparation."
        case let .missingHelper(tool):
            return "The helper \(tool.rawValue) is required for this media flow."
        }
    }
}

private struct PreparedBootSource {
    let rootURL: URL
    let mountedImage: MountedDiskImage?

    func cleanup(using mounter: DiskImageMounter) async throws {
        if let mountedImage {
            try await mounter.detach(mountedImage)
        }
    }
}

struct BootableUtilityService {
    private let logger = Logger(subsystem: "FlashKit", category: "BootableUtilityWrite")
    private let mounter = DiskImageMounter()
    private let diskService = DiskService()
    private let partitioning = PartitioningService()
    private let filesystemService = FilesystemService()
    private let verificationService = VerificationService()
    private let postWriteValidationService = PostWriteValidationService()
    private let privileged = PrivilegedCommandService()
    private let runner = ProcessRunner()
    private let ntfsPopulateService = NTFSPopulateService()

    func createBootableMedia(
        sourceProfile: SourceImageProfile,
        sourceURL: URL,
        targetDisk: ExternalDisk,
        plan: WritePlan,
        volumeLabel: String,
        options: WriteOptions,
        toolchain: ToolchainStatus,
        executionMetadata: BackendWriteExecutionMetadata? = nil,
        progress: @escaping @Sendable (WriteSessionUpdate) async -> Void
    ) async throws {
        let preparedSource = try await prepareSource(from: sourceURL)

        do {
            logger.info("phase=partitioning image=\(sourceProfile.displayName, privacy: .public) target=\(targetDisk.deviceNode, privacy: .public)")
            await progress(.init(phase: "Partitioning", message: "Preparing the target disk for \(plan.summary.lowercased()).", fractionCompleted: 0.08))
            let preparedTarget = try await partitioning.prepareInstallerTarget(plan: plan, targetDisk: targetDisk, volumeLabel: volumeLabel)
            await progress(
                .init(
                    phase: "Partitioning",
                    message: "Prepared the target partition layout.",
                    fractionCompleted: 0.12,
                    details: BackendActivityLogFormatter.partitionWriteLines(for: plan, volumeLabel: volumeLabel)
                )
            )

            try await filesystemService.formatPartition(
                partition: preparedTarget.primaryPartition,
                filesystem: plan.primaryFilesystem ?? .fat32,
                volumeName: volumeLabel,
                toolchain: toolchain
            )

            let refreshedPrimary = try await refreshedPartition(preparedTarget.primaryPartition, on: targetDisk)
            guard let destinationRoot = refreshedPrimary.mountPoint ?? preparedTarget.primaryPartition.mountPoint else {
                throw BootableUtilityServiceError.destinationUnavailable
            }

            logger.info("phase=copying image=\(sourceProfile.displayName, privacy: .public) target=\(targetDisk.deviceNode, privacy: .public)")
            await progress(.init(phase: "Copying files", message: "Copying files to \(destinationRoot.lastPathComponent).", fractionCompleted: 0.22))
            try await copyContents(from: preparedSource.rootURL, to: destinationRoot) { fraction, file in
                await progress(.init(phase: "Copying files", message: file, fractionCompleted: 0.22 + (0.48 * fraction)))
            }

            switch plan.payloadMode {
            case .freeDOS:
                try createFreeDOSConfigFiles(at: destinationRoot)
                guard let helper = toolchain.path(for: .freedosBootHelper) else {
                    throw BootableUtilityServiceError.missingHelper(.freedosBootHelper)
                }
                await progress(.init(phase: "Boot sector", message: "Writing a FreeDOS-compatible boot sector.", fractionCompleted: 0.76))
                logger.info("phase=boot-sector image=\(sourceProfile.displayName, privacy: .public) target=\(targetDisk.deviceNode, privacy: .public)")
                try await privileged.run(helper, arguments: ["write", "--device", refreshedPrimary.deviceNode])
            case .linuxPersistenceCasper, .linuxPersistenceDebian:
                guard let persistencePartition = preparedTarget.auxiliaryPartitions.first else {
                    throw BootableUtilityServiceError.destinationUnavailable
                }
                let persistenceLabel = sourceProfile.persistenceFlavor.partitionLabel ?? "persistence"
                await progress(.init(phase: "Persistence", message: "Creating the ext4 persistence partition.", fractionCompleted: 0.76))
                logger.info("phase=persistence image=\(sourceProfile.displayName, privacy: .public) target=\(targetDisk.deviceNode, privacy: .public)")
                try await filesystemService.formatPartition(
                    partition: persistencePartition,
                    filesystem: .ext4,
                    volumeName: persistenceLabel,
                    toolchain: toolchain
                )
                try await configurePersistencePartition(
                    partition: persistencePartition,
                    flavor: sourceProfile.persistenceFlavor,
                    toolchain: toolchain
                )
                try patchLinuxBootConfig(
                    at: destinationRoot,
                    flavor: sourceProfile.persistenceFlavor,
                    sourceVolumeLabel: sourceProfile.detectedVolumeName,
                    destinationVolumeLabel: volumeLabel
                )
                try applyLinuxBootFixes(sourceProfile.linuxBootFixes, at: destinationRoot)
            case .fat32Extract:
                if sourceProfile.isLinuxBootImage {
                    try patchLinuxBootConfig(
                        at: destinationRoot,
                        flavor: .none,
                        sourceVolumeLabel: sourceProfile.detectedVolumeName,
                        destinationVolumeLabel: volumeLabel
                    )
                    try applyLinuxBootFixes(sourceProfile.linuxBootFixes, at: destinationRoot)
                }
                break
            default:
                break
            }

            if plan.postWriteFixups.contains(.repairEFISystemPartition) {
                await progress(.init(phase: "Repairing EFI", message: "Rebuilding EFI fallback boot files for firmware compatibility.", fractionCompleted: 0.84))
                logger.info("phase=repairing-efi image=\(sourceProfile.displayName, privacy: .public) target=\(targetDisk.deviceNode, privacy: .public)")
                try repairEFISystemPartition(at: destinationRoot, sourceProfile: sourceProfile)
            }

            await progress(.init(phase: "Verifying", message: "Validating the written media.", fractionCompleted: 0.90))
            logger.info("phase=verifying image=\(sourceProfile.displayName, privacy: .public) target=\(targetDisk.deviceNode, privacy: .public)")
            switch plan.payloadMode {
            case .freeDOS, .fat32Extract:
                try verificationService.verifyCopiedManifest(sourceRoot: preparedSource.rootURL, destinationRoot: destinationRoot)
            case .linuxPersistenceCasper, .linuxPersistenceDebian:
                break
            default:
                break
            }

            logger.info("phase=validating image=\(sourceProfile.displayName, privacy: .public) target=\(targetDisk.deviceNode, privacy: .public)")
            let validationResult = await postWriteValidationService.validateWrittenMedia(
                sourceProfile: sourceProfile,
                targetDisk: targetDisk,
                plan: plan,
                executionMetadata: executionMetadata,
                destinationRoot: destinationRoot,
                ntfsDestinationPartition: nil,
                customization: options.customizationProfile,
                toolchain: toolchain,
                ntfsPopulateService: ntfsPopulateService
            )
            await progress(
                .init(
                    phase: "Validating media",
                    message: validationResult.passed ? "Structural validation passed." : (validationResult.failureReason ?? "Structural validation failed."),
                    fractionCompleted: 0.94,
                    details: BackendActivityLogFormatter.validationLines(validationResult)
                )
            )
            guard validationResult.passed else {
                throw MediaValidationServiceError.failed(validationResult)
            }

            await filesystemService.sync()

            if options.ejectWhenFinished {
                await progress(.init(phase: "Ejecting", message: "Ejecting the prepared drive.", fractionCompleted: 0.97))
                logger.info("phase=ejecting image=\(sourceProfile.displayName, privacy: .public) target=\(targetDisk.deviceNode, privacy: .public)")
                _ = try? await runner.run("/usr/sbin/diskutil", arguments: ["eject", targetDisk.deviceNode])
            }

            logger.info("phase=finished image=\(sourceProfile.displayName, privacy: .public) target=\(targetDisk.deviceNode, privacy: .public)")
            await progress(.init(phase: "Finished", message: "Bootable media is ready.", fractionCompleted: 1.0))
            try await preparedSource.cleanup(using: mounter)
        } catch {
            logger.error("phase=failed image=\(sourceProfile.displayName, privacy: .public) target=\(targetDisk.deviceNode, privacy: .public) reason=\(error.localizedDescription, privacy: .public)")
            try? await preparedSource.cleanup(using: mounter)
            throw error
        }
    }

    private func prepareSource(from sourceURL: URL) async throws -> PreparedBootSource {
        let isDirectory = (try? sourceURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        if isDirectory {
            return PreparedBootSource(rootURL: sourceURL, mountedImage: nil)
        }

        let mountedImage = try await mounter.mountImage(at: sourceURL)
        return PreparedBootSource(rootURL: mountedImage.mountPoint, mountedImage: mountedImage)
    }

    private func refreshedPartition(_ partition: DiskPartition, on targetDisk: ExternalDisk) async throws -> DiskPartition {
        let partitions = try await diskService.mountedPartitions(forWholeDisk: targetDisk.identifier)
        return partitions.first(where: { $0.identifier == partition.identifier }) ?? partition
    }

    private func configurePersistencePartition(
        partition: DiskPartition,
        flavor: LinuxPersistenceFlavor,
        toolchain: ToolchainStatus
    ) async throws {
        guard flavor == .debian else {
            return
        }

        guard let debugfs = toolchain.path(for: .debugfs) else {
            throw BootableUtilityServiceError.missingHelper(.debugfs)
        }

        let temporaryConfig = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("conf")
        defer { try? FileManager.default.removeItem(at: temporaryConfig) }
        try "/ union\n".write(to: temporaryConfig, atomically: true, encoding: .utf8)

        try await privileged.run(
            debugfs,
            arguments: [
                "-w",
                "-R", "write \(temporaryConfig.path) persistence.conf",
                partition.deviceNode,
            ]
        )
    }

    private func createFreeDOSConfigFiles(at destinationRoot: URL) throws {
        let fdconfig = """
        !MENUCOLOR=7,0
        MENU
        MENU   FreeDOS Boot Menu
        MENUDEFAULT=1,5
        1? Load FreeDOS with English keyboard support
        1. DISPLAY CON=(EGA,,1)
        1. COUNTRY=001,437,\\KEYBOARD.SYS
        1. KEYB US,437,\\KEYBOARD.SYS
        """
        let autoexec = """
        @ECHO OFF
        SET PATH=\\
        PROMPT $P$G
        """
        try fdconfig.write(to: destinationRoot.appending(path: "FDCONFIG.SYS"), atomically: true, encoding: .utf8)
        try autoexec.write(to: destinationRoot.appending(path: "AUTOEXEC.BAT"), atomically: true, encoding: .utf8)
    }

    private func repairEFISystemPartition(at destinationRoot: URL, sourceProfile: SourceImageProfile) throws {
        guard sourceProfile.hasEFI || sourceProfile.isUEFIShellImage || sourceProfile.applianceProfile == .trueNASInstaller else {
            return
        }

        try ensureFallbackEFIBootFile(
            at: destinationRoot,
            destinationRelativePath: "EFI/BOOT/BOOTX64.EFI",
            candidateRelativePaths: [
                "EFI/BOOT/BOOTX64.EFI",
                "EFI/BOOT/GRUBX64.EFI",
                "EFI/BOOT/SHIMX64.EFI",
                "EFI/ubuntu/grubx64.efi",
                "EFI/ubuntu/shimx64.efi",
                "EFI/debian/grubx64.efi",
                "EFI/debian/shimx64.efi",
                "EFI/kali/grubx64.efi",
                "EFI/kali/shimx64.efi",
                "EFI/arch/grubx64.efi",
                "EFI/fedora/grubx64.efi",
                "EFI/fedora/shimx64.efi",
                "shellx64.efi",
                "boot/loader.efi",
                "efi/boot/loader.efi",
            ]
        )

        try ensureFallbackEFIBootFile(
            at: destinationRoot,
            destinationRelativePath: "EFI/BOOT/BOOTAA64.EFI",
            candidateRelativePaths: [
                "EFI/BOOT/BOOTAA64.EFI",
                "EFI/BOOT/GRUBAA64.EFI",
                "EFI/BOOT/SHIMAA64.EFI",
                "EFI/ubuntu/grubaa64.efi",
                "EFI/ubuntu/shimaa64.efi",
                "EFI/debian/grubaa64.efi",
                "EFI/debian/shimaa64.efi",
                "EFI/kali/grubaa64.efi",
                "EFI/kali/shimaa64.efi",
                "EFI/fedora/grubaa64.efi",
                "EFI/fedora/shimaa64.efi",
                "shellaa64.efi",
            ]
        )
    }

    private func patchLinuxBootConfig(
        at destinationRoot: URL,
        flavor: LinuxPersistenceFlavor,
        sourceVolumeLabel: String?,
        destinationVolumeLabel: String
    ) throws {
        for url in linuxConfigURLs(in: destinationRoot) {
            guard var text = try? String(contentsOf: url, encoding: .utf8) else {
                continue
            }

            let original = text
            text = patchLinuxPersistence(in: text, flavor: flavor)
            text = patchLinuxVolumeLabelReferences(
                in: text,
                sourceVolumeLabel: sourceVolumeLabel,
                destinationVolumeLabel: destinationVolumeLabel
            )

            guard text != original else {
                continue
            }

            try text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func applyLinuxBootFixes(_ fixes: [LinuxBootFix], at destinationRoot: URL) throws {
        for fix in fixes {
            switch fix {
            case .normalizeEFIBootFiles:
                try normalizeLinuxEFIBootFiles(at: destinationRoot)
            case .mirrorGRUBConfig:
                try mirrorLinuxGRUBConfigs(at: destinationRoot)
            case .mirrorSyslinuxConfig:
                try mirrorLinuxSyslinuxConfigs(at: destinationRoot)
            case .rewriteVolumeLabels:
                continue
            }
        }
    }

    private func normalizeLinuxEFIBootFiles(at root: URL) throws {
        try ensureFallbackEFIBootFile(
            at: root,
            destinationRelativePath: "EFI/BOOT/BOOTX64.EFI",
            candidateRelativePaths: [
                "EFI/BOOT/GRUBX64.EFI",
                "EFI/BOOT/SHIMX64.EFI",
                "EFI/ubuntu/grubx64.efi",
                "EFI/ubuntu/shimx64.efi",
                "EFI/debian/grubx64.efi",
                "EFI/debian/shimx64.efi",
                "EFI/kali/grubx64.efi",
                "EFI/kali/shimx64.efi",
                "EFI/arch/grubx64.efi",
                "EFI/fedora/grubx64.efi",
                "EFI/fedora/shimx64.efi",
            ]
        )

        try ensureFallbackEFIBootFile(
            at: root,
            destinationRelativePath: "EFI/BOOT/BOOTAA64.EFI",
            candidateRelativePaths: [
                "EFI/BOOT/GRUBAA64.EFI",
                "EFI/BOOT/SHIMAA64.EFI",
                "EFI/ubuntu/grubaa64.efi",
                "EFI/ubuntu/shimaa64.efi",
                "EFI/debian/grubaa64.efi",
                "EFI/debian/shimaa64.efi",
                "EFI/kali/grubaa64.efi",
                "EFI/kali/shimaa64.efi",
                "EFI/fedora/grubaa64.efi",
                "EFI/fedora/shimaa64.efi",
            ]
        )
    }

    private func ensureFallbackEFIBootFile(
        at root: URL,
        destinationRelativePath: String,
        candidateRelativePaths: [String]
    ) throws {
        guard existingURL(in: root, relativePath: destinationRelativePath) == nil else {
            return
        }

        guard let sourceURL = candidateRelativePaths.compactMap({ existingURL(in: root, relativePath: $0) }).first else {
            return
        }

        let destinationURL = root.appending(path: destinationRelativePath)
        try FileManager.default.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destinationURL.path()) {
            try FileManager.default.removeItem(at: destinationURL)
        }
        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
    }

    private func mirrorLinuxGRUBConfigs(at root: URL) throws {
        try mirrorFileIfNeeded(
            at: root,
            sourceRelativePath: "grub/grub.cfg",
            destinationRelativePath: "boot/grub/grub.cfg"
        )
        try mirrorFileIfNeeded(
            at: root,
            sourceRelativePath: "boot/grub/grub.cfg",
            destinationRelativePath: "grub/grub.cfg"
        )
    }

    private func mirrorLinuxSyslinuxConfigs(at root: URL) throws {
        for relativePath in ["isolinux/isolinux.cfg", "isolinux/txt.cfg", "isolinux/live.cfg"] {
            let destination = relativePath.replacingOccurrences(of: "isolinux/", with: "syslinux/")
            try mirrorFileIfNeeded(at: root, sourceRelativePath: relativePath, destinationRelativePath: destination)
        }

        for relativePath in ["syslinux/syslinux.cfg", "syslinux/txt.cfg", "syslinux/live.cfg"] {
            let destination = relativePath.replacingOccurrences(of: "syslinux/", with: "isolinux/")
            try mirrorFileIfNeeded(at: root, sourceRelativePath: relativePath, destinationRelativePath: destination)
        }
    }

    private func mirrorFileIfNeeded(
        at root: URL,
        sourceRelativePath: String,
        destinationRelativePath: String
    ) throws {
        guard existingURL(in: root, relativePath: destinationRelativePath) == nil,
              let sourceURL = existingURL(in: root, relativePath: sourceRelativePath) else {
            return
        }

        let destinationURL = root.appending(path: destinationRelativePath)
        try FileManager.default.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destinationURL.path()) {
            try FileManager.default.removeItem(at: destinationURL)
        }
        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
    }

    private func patchLinuxPersistence(in text: String, flavor: LinuxPersistenceFlavor) -> String {
        guard let argument = flavor.kernelArgument else {
            return text
        }

        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let patchedLines = lines.map { line -> String in
            let lowercased = line.lowercased()
            guard !lowercased.contains(argument.lowercased()) else {
                return line
            }
            guard lowercased.contains("append ")
                || lowercased.contains(" linux ")
                || lowercased.hasPrefix("linux ")
                || lowercased.hasPrefix("linuxefi ")
                || lowercased.contains(" kernel ") else {
                return line
            }

            if flavor == .casper {
                if line.range(of: "file=/cdrom/preseed", options: .caseInsensitive) != nil {
                    return line.replacingOccurrences(of: "file=/cdrom/preseed", with: "persistent file=/cdrom/preseed", options: .caseInsensitive)
                }
                if line.range(of: "boot=casper", options: .caseInsensitive) != nil {
                    return line.replacingOccurrences(of: "boot=casper", with: "boot=casper persistent", options: .caseInsensitive)
                }
                if line.range(of: "/casper/vmlinuz", options: .caseInsensitive) != nil {
                    return line.replacingOccurrences(of: "/casper/vmlinuz", with: "/casper/vmlinuz persistent", options: .caseInsensitive)
                }
            }

            if flavor == .debian, line.range(of: "boot=live", options: .caseInsensitive) != nil {
                return line.replacingOccurrences(of: "boot=live", with: "boot=live persistence", options: .caseInsensitive)
            }

            return line + " " + argument
        }

        return patchedLines.joined(separator: "\n")
    }

    private func patchLinuxVolumeLabelReferences(
        in text: String,
        sourceVolumeLabel: String?,
        destinationVolumeLabel: String
    ) -> String {
        guard let sourceVolumeLabel,
              !sourceVolumeLabel.isEmpty,
              sourceVolumeLabel.caseInsensitiveCompare(destinationVolumeLabel) != .orderedSame else {
            return text
        }

        let sourceVariants = labelVariants(for: sourceVolumeLabel)
        let destinationVariants = labelVariants(for: destinationVolumeLabel)
        var patched = text

        for (sourceVariant, destinationVariant) in zip(sourceVariants, destinationVariants).sorted(by: { $0.0.count > $1.0.count }) {
            guard sourceVariant != destinationVariant else {
                continue
            }
            patched = patched.replacingOccurrences(of: sourceVariant, with: destinationVariant)
        }

        return patched
    }

    private func labelVariants(for label: String) -> [String] {
        [
            label,
            label.replacingOccurrences(of: " ", with: "\\x20"),
            label.replacingOccurrences(of: " ", with: "\\040"),
            label.replacingOccurrences(of: " ", with: "%20"),
            label.replacingOccurrences(of: " ", with: "_"),
        ]
    }

    private func linuxConfigURLs(in root: URL) -> [URL] {
        let fileManager = FileManager.default
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .fileSizeKey]
        let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])
        var urls: [URL] = []

        while let item = enumerator?.nextObject() as? URL {
            guard let values = try? item.resourceValues(forKeys: keys),
                  values.isDirectory != true else {
                continue
            }

            let relativePath = relativePath(for: item, under: root).lowercased()
            let size = values.fileSize ?? 0
            guard size <= 2_000_000 else {
                continue
            }

            if isLinuxConfigCandidate(relativePath) {
                urls.append(item)
            }
        }

        return urls
    }

    private func isLinuxConfigCandidate(_ relativePath: String) -> Bool {
        let configExtensions = [".cfg", ".conf", ".lst"]
        if configExtensions.contains(where: { relativePath.hasSuffix($0) }) {
            return true
        }

        return relativePath.hasPrefix("boot/grub/")
            || relativePath.hasPrefix("grub/")
            || relativePath.hasPrefix("isolinux/")
            || relativePath.hasPrefix("syslinux/")
            || relativePath.hasPrefix("loader/entries/")
    }

    private func copyContents(
        from sourceRoot: URL,
        to destinationRoot: URL,
        progress: @escaping @Sendable (Double, String) async -> Void
    ) async throws {
        let manifest = try buildCopyManifest(from: sourceRoot)
        let fileManager = FileManager.default
        let totalBytes = max(manifest.totalBytes, 1)
        var copiedBytes: Int64 = 0

        for directory in manifest.directories {
            try fileManager.createDirectory(at: destinationRoot.appending(path: directory), withIntermediateDirectories: true)
        }

        for file in manifest.files {
            let destinationURL = destinationRoot.appending(path: file.relativePath)
            try fileManager.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: destinationURL.path()) {
                try fileManager.removeItem(at: destinationURL)
            }
            try fileManager.copyItem(at: file.sourceURL, to: destinationURL)
            copiedBytes += file.size
            await progress(Double(copiedBytes) / Double(totalBytes), "Copying \(file.relativePath)")
        }
    }

    private func buildCopyManifest(from root: URL) throws -> CopyManifest {
        let fileManager = FileManager.default
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .fileSizeKey]
        let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])

        var directories: [String] = []
        var files: [CopyEntry] = []
        var totalBytes: Int64 = 0

        while let item = enumerator?.nextObject() as? URL {
            let relativePath = relativePath(for: item, under: root)
            let values = try item.resourceValues(forKeys: keys)
            if values.isDirectory == true {
                directories.append(relativePath)
                continue
            }

            let size = Int64(values.fileSize ?? 0)
            totalBytes += size
            files.append(CopyEntry(sourceURL: item, relativePath: relativePath, size: size))
        }

        return CopyManifest(
            directories: directories.sorted(),
            files: files.sorted { $0.relativePath < $1.relativePath },
            totalBytes: totalBytes
        )
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

    private func relativePath(for url: URL, under root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let fullPath = url.standardizedFileURL.path
        if fullPath.hasPrefix(rootPath + "/") {
            return String(fullPath.dropFirst(rootPath.count + 1))
        }
        return url.lastPathComponent
    }
}

private struct CopyManifest {
    let directories: [String]
    let files: [CopyEntry]
    let totalBytes: Int64
}

private struct CopyEntry {
    let sourceURL: URL
    let relativePath: String
    let size: Int64
}
