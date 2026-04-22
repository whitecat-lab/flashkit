import Foundation

enum BootValidationServiceError: LocalizedError {
    case missingArtifact(String)
    case invalidBootSector
    case missingPersistenceConfig
    case missingPersistencePartition
    case unexpectedFilesystem(String)

    var errorDescription: String? {
        switch self {
        case let .missingArtifact(path):
            return "Static boot validation could not find \(path) on the destination media."
        case .invalidBootSector:
            return "Static boot validation could not confirm a DOS-compatible boot sector on the destination media."
        case .missingPersistenceConfig:
            return "The Linux persistence configuration was not written to the destination media."
        case .missingPersistencePartition:
            return "The Linux persistence partition was not created on the destination media."
        case let .unexpectedFilesystem(description):
            return description
        }
    }
}

struct BootValidationService {
    private let diskService = DiskService()
    private let privileged = PrivilegedCommandService()

    func validateWindowsMedia(
        sourceProfile: SourceImageProfile,
        destinationRoot: URL?,
        ntfsDestinationPartition: DiskPartition?,
        targetDisk: ExternalDisk,
        plan: WritePlan,
        customization: CustomizationProfile,
        toolchain: ToolchainStatus,
        ntfsPopulateService: NTFSPopulateService
    ) async throws {
        if plan.usesUEFINTFSPath {
            let partitions = try await diskService.mountedPartitions(forWholeDisk: targetDisk.identifier)
            guard partitions.count >= 2 else {
                throw BootValidationServiceError.missingArtifact("UEFI:NTFS helper partition")
            }
        }

        var required = Set<String>()
        if sourceProfile.hasEFI || plan.postWriteFixups.contains(.windows7EFIFallback) {
            required.insert("EFI/BOOT/BOOTX64.EFI")
        }
        if sourceProfile.hasBIOS || plan.postWriteFixups.contains(.biosWinPEFixup) {
            required.insert("BOOTMGR")
            required.insert("boot/BCD")
        }
        if customization.bypassSecureBootTPMRAMChecks {
            required.insert("sources/appraiserres.dll")
        }
        if customization.isEnabled && sourceProfile.windows?.hasPantherUnattend != true {
            required.insert(customization.preferredPlacement.relativePath)
        }

        try await assertArtifacts(
            required,
            destinationRoot: destinationRoot,
            ntfsDestinationPartition: ntfsDestinationPartition,
            toolchain: toolchain,
            ntfsPopulateService: ntfsPopulateService
        )
    }

    func validateFreeDOSMedia(
        destinationRoot: URL,
        primaryPartition: DiskPartition
    ) async throws {
        try await validateFAT32BootPartition(primaryPartition)

        for artifact in ["COMMAND.COM", "KERNEL.SYS", "FDCONFIG.SYS", "AUTOEXEC.BAT"] {
            guard existingURL(in: destinationRoot, relativePath: artifact) != nil else {
                throw BootValidationServiceError.missingArtifact(artifact)
            }
        }

        let sectorDump = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("bin")
        defer { try? FileManager.default.removeItem(at: sectorDump) }

        try await privileged.run(
            "/bin/dd",
            arguments: [
                "if=\(primaryPartition.deviceNode)",
                "of=\(sectorDump.path)",
                "bs=512",
                "count=1",
            ]
        )

        let sectorData = try Data(contentsOf: sectorDump)
        guard sectorData.count >= 512, sectorData[510] == 0x55, sectorData[511] == 0xAA else {
            throw BootValidationServiceError.invalidBootSector
        }
    }

    func validateLinuxPersistenceMedia(
        destinationRoot: URL,
        targetDisk: ExternalDisk,
        persistenceFlavor: LinuxPersistenceFlavor,
        primaryPartition: DiskPartition
    ) async throws {
        try await validateFAT32BootPartition(primaryPartition)

        let partitions = try await diskService.mountedPartitions(forWholeDisk: targetDisk.identifier)
        guard partitions.count >= 2 else {
            throw BootValidationServiceError.missingPersistencePartition
        }

        switch persistenceFlavor {
        case .casper:
            try assertTextContains(
                inAnyOf: ["boot/grub/grub.cfg", "boot/grub/loopback.cfg", "isolinux/txt.cfg", "syslinux/txt.cfg"],
                root: destinationRoot,
                needle: "persistent"
            )
        case .debian:
            try assertTextContains(
                inAnyOf: ["boot/grub/grub.cfg", "boot/grub/loopback.cfg", "isolinux/live.cfg", "syslinux/live.cfg"],
                root: destinationRoot,
                needle: "persistence"
            )
        case .none:
            break
        }
    }

    func validateLinuxMedia(
        destinationRoot: URL,
        sourceProfile: SourceImageProfile,
        primaryPartition: DiskPartition
    ) async throws {
        if sourceProfile.requiresFAT32FirmwareBoot {
            try await validateFAT32BootPartition(primaryPartition)
        }

        if sourceProfile.hasEFI {
            try assertAnyArtifact(
                [
                    "EFI/BOOT/BOOTX64.EFI",
                    "EFI/BOOT/BOOTAA64.EFI",
                    "EFI/BOOT/BOOTIA32.EFI",
                    "EFI/BOOT/GRUBX64.EFI",
                    "EFI/BOOT/GRUBAA64.EFI",
                ],
                root: destinationRoot,
                description: "Linux EFI bootloader"
            )
        }

        if sourceProfile.hasBIOS {
            try assertAnyArtifact(
                [
                    "isolinux/isolinux.bin",
                    "syslinux/syslinux.cfg",
                    "isolinux/isolinux.cfg",
                    "boot/grub/grub.cfg",
                    "grub/grub.cfg",
                ],
                root: destinationRoot,
                description: "Linux BIOS boot artifact"
            )
        }

        try assertAnyArtifact(
            [
                "boot/grub/grub.cfg",
                "boot/grub/loopback.cfg",
                "grub/grub.cfg",
                "isolinux/isolinux.cfg",
                "syslinux/syslinux.cfg",
                "casper/vmlinuz",
                "live/vmlinuz",
                ".treeinfo",
            ],
            root: destinationRoot,
            description: "Linux boot configuration"
        )
    }

    func validateUEFIShellMedia(destinationRoot: URL, primaryPartition: DiskPartition) async throws {
        try await validateFAT32BootPartition(primaryPartition)

        let candidates = [
            "EFI/BOOT/BOOTX64.EFI",
            "EFI/BOOT/BOOTAA64.EFI",
            "shellx64.efi",
            "shellaa64.efi",
            "startup.nsh",
        ]

        guard candidates.contains(where: { existingURL(in: destinationRoot, relativePath: $0) != nil }) else {
            throw BootValidationServiceError.missingArtifact("UEFI Shell boot file")
        }
    }

    func validateFAT32BootPartition(_ primaryPartition: DiskPartition) async throws {
        let info = try await diskService.diskInfo(for: primaryPartition.identifier)
        let description = [
            info["FilesystemName"] as? String,
            info["FilesystemType"] as? String,
            info["Content"] as? String,
        ]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")

        guard description.contains("fat") || description.contains("ms-dos") || description.contains("msdos") else {
            throw BootValidationServiceError.unexpectedFilesystem(
                "Firmware-facing extracted media must stay on FAT32, but \(primaryPartition.identifier) was formatted as \(description.isEmpty ? "an unknown filesystem" : description)."
            )
        }
    }

    func validateApplianceMedia(
        appliance: ApplianceProfile,
        destinationRoots: [URL],
        sourceProfile: SourceImageProfile
    ) throws {
        switch appliance {
        case .proxmoxInstaller:
            if sourceProfile.hasEFI {
                try assertAnyArtifact(
                    [
                        "EFI/BOOT/BOOTX64.EFI",
                        "EFI/BOOT/GRUBX64.EFI",
                        "EFI/proxmox/grubx64.efi",
                    ],
                    roots: destinationRoots,
                    description: "Proxmox EFI bootloader"
                )
            }

            try assertAnyArtifact(
                [
                    "boot/grub/grub.cfg",
                    "grub/grub.cfg",
                    "isolinux/isolinux.cfg",
                    "isolinux/isolinux.bin",
                ],
                roots: destinationRoots,
                description: "Proxmox boot configuration"
            )
        case .trueNASInstaller:
            try assertAnyArtifact(
                [
                    "EFI/BOOT/BOOTX64.EFI",
                    "boot/loader.efi",
                    "efi/boot/loader.efi",
                    "boot/defaults/loader.conf",
                ],
                roots: destinationRoots,
                description: "TrueNAS boot partition"
            )
        case .openWrtImage:
            return
        }
    }

    private func assertArtifacts(
        _ artifacts: Set<String>,
        destinationRoot: URL?,
        ntfsDestinationPartition: DiskPartition?,
        toolchain: ToolchainStatus,
        ntfsPopulateService: NTFSPopulateService
    ) async throws {
        for artifact in artifacts {
            if let destinationRoot {
                guard existingURL(in: destinationRoot, relativePath: artifact) != nil else {
                    throw BootValidationServiceError.missingArtifact(artifact)
                }
            } else if let ntfsDestinationPartition {
                try await ntfsPopulateService.assertFileExists(
                    on: ntfsDestinationPartition,
                    relativePath: artifact,
                    toolchain: toolchain
                )
            }
        }
    }

    private func assertTextContains(inAnyOf candidates: [String], root: URL, needle: String) throws {
        for candidate in candidates {
            guard let url = existingURL(in: root, relativePath: candidate) else {
                continue
            }
            if let text = try? String(contentsOf: url, encoding: .utf8),
               text.localizedCaseInsensitiveContains(needle) {
                return
            }
        }

        throw BootValidationServiceError.missingArtifact(needle)
    }

    private func assertAnyArtifact(_ candidates: [String], root: URL, description: String) throws {
        guard candidates.contains(where: { existingURL(in: root, relativePath: $0) != nil }) else {
            throw BootValidationServiceError.missingArtifact(description)
        }
    }

    private func assertAnyArtifact(_ candidates: [String], roots: [URL], description: String) throws {
        guard roots.contains(where: { root in
            candidates.contains(where: { existingURL(in: root, relativePath: $0) != nil })
        }) else {
            throw BootValidationServiceError.missingArtifact(description)
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
}
