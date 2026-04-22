import Foundation

struct WritePlanBuilder {
    func buildPlan(
        for profile: SourceImageProfile,
        targetDisk: ExternalDisk?,
        toolchain: ToolchainStatus,
        options: WriteOptions = WriteOptions()
    ) -> WritePlan {
        if let applianceProfile = profile.applianceProfile {
            return buildAppliancePlan(
                profile: profile,
                applianceProfile: applianceProfile,
                targetDisk: targetDisk,
                toolchain: toolchain,
                options: options
            )
        }

        if profile.supportsDOSBoot {
            return buildFreeDOSPlan(toolchain: toolchain)
        }

        if profile.supportsPersistence && options.enableLinuxPersistence {
            return buildLinuxPersistencePlan(profile: profile, toolchain: toolchain, options: options)
        }

        if profile.isLinuxBootImage && profile.isoHybridStyle.isHybrid
            && (!profile.oversizedPaths.isEmpty || profile.linuxBootFixes.isEmpty) {
            return buildHybridLinuxDirectPlan(profile: profile, targetDisk: targetDisk, toolchain: toolchain)
        }

        if profile.isLinuxBootImage,
           profile.oversizedPaths.isEmpty,
           profile.format == .iso || profile.format == .udfISO || profile.format == .dmg || profile.format == .unknown {
            return buildExtractedFAT32Plan(
                profile: profile,
                toolchain: toolchain,
                payloadMode: .fat32Extract,
                summary: profile.requiresLinuxExtractionRebuild
                    ? "Extract and rebuild the Linux image onto a FAT32 USB with distro-specific boot fixes."
                    : "Extract the Linux image onto a FAT32 bootable USB and patch common distro boot config references."
            )
        }

        if profile.isUEFIShellImage && profile.oversizedPaths.isEmpty {
            return buildExtractedFAT32Plan(
                profile: profile,
                toolchain: toolchain,
                payloadMode: .fat32Extract,
                summary: "Extract the UEFI Shell image onto a FAT32 bootable USB."
            )
        }

        if !profile.isWindowsInstaller,
           profile.hasEFI,
           !profile.oversizedPaths.isEmpty,
           profile.format == .iso || profile.format == .udfISO || profile.format == .dmg {
            return buildGenericOversizedEFIPlan(profile: profile, toolchain: toolchain)
        }

        if profile.supportedMediaModes.contains(.windowsInstaller), let windows = profile.windows {
            return buildWindowsInstallerPlan(profile: profile, windows: windows, toolchain: toolchain, options: options)
        }

        if profile.format == .wim || profile.format == .esd {
            return WritePlan(
                mediaMode: .windowsInstaller,
                payloadMode: .directRaw,
                partitionScheme: .gpt,
                targetSystem: .dual,
                primaryFilesystem: nil,
                partitionLayouts: [],
                helperRequirements: [],
                postWriteFixups: [],
                verificationMode: .none,
                verificationSteps: [],
                warnings: ["Select a Windows ISO or extracted setup directory as Boot Assets Source before writing this standalone install image."],
                summary: "Standalone WIM/ESD sources need Windows setup boot assets before they can be rebuilt into bootable installer media.",
                isBlocked: true,
                blockingReason: "Select a valid Boot Assets Source so the standalone install image can be rebuilt into Windows installer media."
            )
        }

        if profile.format == .vhd || profile.format == .vhdx {
            let helperRequirements = [
                HelperRequirement(tool: .diskutil, reason: "Prepare and unmount the target disk"),
                HelperRequirement(tool: .dd, reason: "Write the restored image data"),
                HelperRequirement(tool: .qemuImg, reason: "Restore \(profile.format.rawValue.uppercased()) data onto the target disk"),
            ]
            let blockingReason = toolchain.blockingReason(for: helperRequirements)
            return WritePlan(
                mediaMode: .driveRestore,
                payloadMode: .directRaw,
                partitionScheme: .superFloppy,
                targetSystem: .dual,
                primaryFilesystem: nil,
                partitionLayouts: [],
                helperRequirements: helperRequirements,
                postWriteFixups: [],
                verificationMode: .vhdxRoundTrip,
                verificationSteps: ["Compare the restored target against the converted raw image"],
                warnings: [],
                summary: "Restore the selected drive image onto the target disk.",
                isBlocked: blockingReason != nil,
                blockingReason: blockingReason
            )
        }

        let oversizeWarning = targetDisk.map { disk in
            profile.size > disk.size ? "The source image is larger than the selected disk." : nil
        } ?? nil
        var directImageRequirements = [
            HelperRequirement(tool: .diskutil, reason: "Prepare and unmount the target disk"),
            HelperRequirement(tool: .dd, reason: "Write the source image directly to the raw device"),
        ]
        if RawDiskImageService.compression(for: profile.sourceURL) == .xz {
            directImageRequirements.append(
                HelperRequirement(tool: .xz, reason: "Decompress XZ-compressed raw images before writing")
            )
        }
        let directImageBlocker = toolchain.blockingReason(for: directImageRequirements)
        let compressionWarnings = rawImageWarnings(for: profile)

        return WritePlan(
            mediaMode: .directImage,
            payloadMode: .directRaw,
            partitionScheme: .superFloppy,
            targetSystem: .dual,
            primaryFilesystem: nil,
            partitionLayouts: [],
            helperRequirements: directImageRequirements,
            postWriteFixups: [],
            verificationMode: .rawByteCompare,
            verificationSteps: ["Compare the written target against the source image", "Sync writes to disk"],
            warnings: (oversizeWarning.map { [$0] } ?? []) + compressionWarnings,
            summary: "Write the source image directly to the raw removable device.",
            isBlocked: oversizeWarning != nil || directImageBlocker != nil,
            blockingReason: oversizeWarning ?? directImageBlocker
        )
    }

    private func rawImageWarnings(for profile: SourceImageProfile) -> [String] {
        guard let compression = RawDiskImageService.compression(for: profile.sourceURL) else {
            return []
        }

        return ["This \(compression.displayName)-compressed raw image will be decompressed to a temporary .img file before writing."]
    }

    private func buildAppliancePlan(
        profile: SourceImageProfile,
        applianceProfile: ApplianceProfile,
        targetDisk: ExternalDisk?,
        toolchain: ToolchainStatus,
        options: WriteOptions
    ) -> WritePlan {
        _ = options

        switch applianceProfile {
        case .proxmoxInstaller:
            if profile.format == .dd || profile.isoHybridStyle.isHybrid {
                return buildDirectApplianceImagePlan(
                    profile: profile,
                    applianceProfile: applianceProfile,
                    targetDisk: targetDisk,
                    toolchain: toolchain,
                    summary: "Write the Proxmox installer directly as appliance media and verify its EFI boot files.",
                    verificationMode: .bootArtifacts
                )
            }

            return buildExtractedFAT32Plan(
                profile: profile,
                toolchain: toolchain,
                payloadMode: .fat32Extract,
                summary: "Rebuild the Proxmox installer onto a firmware-friendly FAT32 USB and repair EFI fallback files when needed."
            )
        case .trueNASInstaller:
            if profile.format == .dd {
                return buildDirectApplianceImagePlan(
                    profile: profile,
                    applianceProfile: applianceProfile,
                    targetDisk: targetDisk,
                    toolchain: toolchain,
                    summary: "Write the TrueNAS installer directly to preserve its appliance partitioning and labels.",
                    verificationMode: .bootArtifacts
                )
            }

            return buildExtractedFAT32Plan(
                profile: profile,
                toolchain: toolchain,
                payloadMode: .fat32Extract,
                summary: "Rebuild the TrueNAS installer onto a FAT32 USB, force GPT when EFI firmware needs it, and repair broken EFI boot files."
            )
        case .openWrtImage:
            return buildDirectApplianceImagePlan(
                profile: profile,
                applianceProfile: applianceProfile,
                targetDisk: targetDisk,
                toolchain: toolchain,
                summary: "Write the OpenWrt image raw without repartitioning, formatting, or extracting it.",
                verificationMode: .rawByteCompare
            )
        }
    }

    private func buildDirectApplianceImagePlan(
        profile: SourceImageProfile,
        applianceProfile: ApplianceProfile,
        targetDisk: ExternalDisk?,
        toolchain: ToolchainStatus,
        summary: String,
        verificationMode: VerificationMode
    ) -> WritePlan {
        let oversizeWarning = targetDisk.map { disk in
            profile.size > disk.size ? "The source image is larger than the selected disk." : nil
        } ?? nil

        var helperRequirements = [
            HelperRequirement(tool: .diskutil, reason: "Prepare and unmount the target disk"),
            HelperRequirement(tool: .dd, reason: "Write the appliance image directly to the raw device"),
        ]
        if RawDiskImageService.compression(for: profile.sourceURL) == .xz {
            helperRequirements.append(
                HelperRequirement(tool: .xz, reason: "Decompress XZ-compressed appliance images before writing")
            )
        }

        let blockingReason = toolchain.blockingReason(for: helperRequirements)
        var warnings = profile.notes + rawImageWarnings(for: profile)

        if applianceProfile == .proxmoxInstaller && profile.isoHybridStyle.isHybrid {
            warnings.append("Detected a hybrid Proxmox installer ISO. FlashKit will preserve the original hybrid layout.")
        }
        if applianceProfile == .openWrtImage {
            warnings.append("OpenWrt appliance images are always raw-written and never rebuilt into filesystems.")
        }

        return WritePlan(
            mediaMode: .directImage,
            payloadMode: .directRaw,
            partitionScheme: .superFloppy,
            targetSystem: profile.preferredTargetSystem,
            primaryFilesystem: nil,
            partitionLayouts: [],
            helperRequirements: helperRequirements,
            postWriteFixups: [],
            verificationMode: verificationMode,
            verificationSteps: applianceProfile == .openWrtImage
                ? ["Compare the written target against the appliance image", "Sync writes to disk"]
                : ["Compare the written target against the appliance image", "Validate the expected appliance boot artifacts", "Sync writes to disk"],
            warnings: warnings + (oversizeWarning.map { [$0] } ?? []),
            summary: summary,
            isBlocked: oversizeWarning != nil || blockingReason != nil,
            blockingReason: oversizeWarning ?? blockingReason
        )
    }

    private func buildHybridLinuxDirectPlan(
        profile: SourceImageProfile,
        targetDisk: ExternalDisk?,
        toolchain: ToolchainStatus
    ) -> WritePlan {
        let oversizeWarning = targetDisk.map { disk in
            profile.size > disk.size ? "The source image is larger than the selected disk." : nil
        } ?? nil
        let helperRequirements = [
            HelperRequirement(tool: .diskutil, reason: "Prepare and unmount the target disk"),
            HelperRequirement(tool: .dd, reason: "Write the hybrid Linux ISO directly to the raw device"),
        ]
        let blockingReason = toolchain.blockingReason(for: helperRequirements)

        var warnings = profile.notes
        if !profile.linuxBootFixes.isEmpty && !profile.oversizedPaths.isEmpty {
            warnings.append("This hybrid Linux ISO has oversized payload files, so FlashKit will preserve the original raw layout instead of extracting and rebuilding its fixups.")
        }

        return WritePlan(
            mediaMode: .directImage,
            payloadMode: .directRaw,
            partitionScheme: .superFloppy,
            targetSystem: profile.preferredTargetSystem,
            primaryFilesystem: nil,
            partitionLayouts: [],
            helperRequirements: helperRequirements,
            postWriteFixups: [],
            verificationMode: .rawByteCompare,
            verificationSteps: [
                "Compare the written target against the source hybrid ISO",
                "Sync writes to disk",
            ],
            warnings: warnings + (oversizeWarning.map { [$0] } ?? []),
            summary: "Write the hybrid Linux ISO directly to preserve its original bootloader layout.",
            isBlocked: oversizeWarning != nil || blockingReason != nil,
            blockingReason: oversizeWarning ?? blockingReason
        )
    }

    private func buildGenericOversizedEFIPlan(
        profile: SourceImageProfile,
        toolchain: ToolchainStatus
    ) -> WritePlan {
        let targetSystem = profile.preferredTargetSystem
        let partitionScheme = profile.preferredRebuildPartitionScheme

        let helperRequirements = [
            HelperRequirement(tool: .diskutil, reason: "Prepare and partition the target USB"),
            HelperRequirement(tool: .hdiutil, reason: "Mount the source image"),
            HelperRequirement(tool: .dd, reason: "Write the UEFI:NTFS helper image"),
            HelperRequirement(tool: .uefiNTFSImage, reason: "Stage the UEFI:NTFS boot bridge image"),
        ]
        let blockingReason = toolchain.blockingReason(for: helperRequirements)

        return WritePlan(
            mediaMode: .directImage,
            payloadMode: .genericOversizedEfi,
            partitionScheme: partitionScheme,
            targetSystem: targetSystem,
            primaryFilesystem: .exfat,
            partitionLayouts: [
                PartitionLayout(name: "UEFI_NTFS", filesystem: .fat32, sizeMiB: 1, description: "Boot bridge partition"),
                PartitionLayout(name: "GENERIC", filesystem: .exfat, sizeMiB: nil, description: "Large-file EFI payload"),
            ],
            helperRequirements: helperRequirements,
            postWriteFixups: [],
            verificationMode: .windowsInstallerManifest,
            verificationSteps: [
                "Verify the copied destination manifest against the mounted source image",
                "Sync all pending writes",
            ],
            warnings: profile.notes + ["The source contains EFI payload files too large for FAT32, so the planner switched to the generic oversized-EFI path."],
            summary: "Use the generic oversized-EFI path with a helper boot partition and an ExFAT payload partition.",
            isBlocked: blockingReason != nil,
            blockingReason: blockingReason
        )
    }

    private func buildExtractedFAT32Plan(
        profile: SourceImageProfile,
        toolchain: ToolchainStatus,
        payloadMode: WindowsInstallerPayloadMode,
        summary: String
    ) -> WritePlan {
        let targetSystem = profile.preferredTargetSystem
        let partitionScheme = profile.preferredRebuildPartitionScheme

        let helperRequirements = [
            HelperRequirement(tool: .diskutil, reason: "Prepare and partition the target USB"),
            HelperRequirement(tool: .hdiutil, reason: "Mount the source image"),
        ]
        let blockingReason = toolchain.blockingReason(for: helperRequirements)
        var postWriteFixups: [PostWriteFixupStep] = []
        if profile.requiresEFIRepairOnExtractedMedia {
            postWriteFixups.append(.repairEFISystemPartition)
        }

        var warnings = profile.notes
        if profile.requiresFAT32FirmwareBoot {
            warnings.append("FAT32 will be enforced for firmware-facing boot compatibility on this extracted media.")
        }

        return WritePlan(
            mediaMode: .directImage,
            payloadMode: payloadMode,
            partitionScheme: partitionScheme,
            targetSystem: targetSystem,
            primaryFilesystem: .fat32,
            partitionLayouts: [
                PartitionLayout(name: "BOOT", filesystem: .fat32, sizeMiB: nil, description: "Bootable extracted payload")
            ],
            helperRequirements: helperRequirements,
            postWriteFixups: postWriteFixups,
            verificationMode: .bootArtifacts,
            verificationSteps: [
                "Verify the copied destination manifest against the mounted source image",
                "Validate the expected boot artifacts for the extracted media",
            ],
            warnings: warnings,
            summary: summary,
            isBlocked: blockingReason != nil,
            blockingReason: blockingReason
        )
    }

    private func buildFreeDOSPlan(toolchain: ToolchainStatus) -> WritePlan {
        let helperRequirements = [
            HelperRequirement(tool: .diskutil, reason: "Prepare and partition the target USB"),
            HelperRequirement(tool: .freedosBootHelper, reason: "Write a FreeDOS-compatible FAT boot sector"),
        ]
        let blockingReason = toolchain.blockingReason(for: helperRequirements)

        return WritePlan(
            mediaMode: .directImage,
            payloadMode: .freeDOS,
            partitionScheme: .mbr,
            targetSystem: .bios,
            primaryFilesystem: .fat32,
            partitionLayouts: [
                PartitionLayout(name: "FREEDOS", filesystem: .fat32, sizeMiB: nil, description: "Bootable FreeDOS payload")
            ],
            helperRequirements: helperRequirements,
            postWriteFixups: [.freeDOSBootSector],
            verificationMode: .bootArtifacts,
            verificationSteps: [
                "Verify that COMMAND.COM and KERNEL.SYS exist on the destination",
                "Validate the FAT boot sector for the FreeDOS payload",
            ],
            warnings: [],
            summary: "Create a bootable FreeDOS USB from the bundled FreeDOS system files.",
            isBlocked: blockingReason != nil,
            blockingReason: blockingReason
        )
    }

    private func buildLinuxPersistencePlan(
        profile: SourceImageProfile,
        toolchain: ToolchainStatus,
        options: WriteOptions
    ) -> WritePlan {
        if !profile.oversizedPaths.isEmpty {
            return WritePlan(
                mediaMode: .directImage,
                payloadMode: profile.persistenceFlavor == .debian ? .linuxPersistenceDebian : .linuxPersistenceCasper,
                partitionScheme: .mbr,
                targetSystem: profile.preferredTargetSystem,
                primaryFilesystem: .fat32,
                partitionLayouts: [],
                helperRequirements: [],
                postWriteFixups: [],
                verificationMode: .bootArtifacts,
                verificationSteps: [],
                warnings: profile.notes,
                summary: "Linux persistence is only available when the live image payload fits on a FAT32 boot partition.",
                isBlocked: true,
                blockingReason: "This Linux image contains payload files too large for FAT32, so the persistence workflow is blocked."
            )
        }

        let helperRequirements = [
            HelperRequirement(tool: .diskutil, reason: "Prepare and partition the target USB"),
            HelperRequirement(tool: .hdiutil, reason: "Mount the source image"),
            HelperRequirement(tool: .mke2fs, reason: "Create the ext4 persistence partition"),
        ] + (profile.persistenceFlavor == .debian ? [HelperRequirement(tool: .debugfs, reason: "Write persistence.conf into the ext4 persistence partition")] : [])
        let blockingReason = toolchain.blockingReason(for: helperRequirements)
        let payloadMode: WindowsInstallerPayloadMode = profile.persistenceFlavor == .debian ? .linuxPersistenceDebian : .linuxPersistenceCasper
        let label = profile.persistenceFlavor.partitionLabel ?? "persistence"
        let distroName = profile.linuxDistribution.displayName ?? "Linux"
        var postWriteFixups: [PostWriteFixupStep] = [.linuxPersistenceConfig]
        if profile.requiresEFIRepairOnExtractedMedia {
            postWriteFixups.append(.repairEFISystemPartition)
        }

        return WritePlan(
            mediaMode: .directImage,
            payloadMode: payloadMode,
            partitionScheme: profile.preferredRebuildPartitionScheme,
            targetSystem: profile.preferredTargetSystem,
            primaryFilesystem: .fat32,
            partitionLayouts: [
                PartitionLayout(name: "LIVEUSB", filesystem: .fat32, sizeMiB: nil, description: "Bootable Linux payload"),
                PartitionLayout(name: label, filesystem: .ext4, sizeMiB: options.linuxPersistenceSizeMiB, description: "Linux persistence partition"),
            ],
            helperRequirements: helperRequirements,
            postWriteFixups: postWriteFixups,
            verificationMode: .bootArtifacts,
            verificationSteps: [
                "Validate the Linux boot config for the persistence kernel argument",
                "Verify the persistence partition label and expected config files",
            ],
            warnings: profile.notes,
            summary: "Extract the live \(distroName) image to FAT32 and add an ext4 persistence partition.",
            isBlocked: blockingReason != nil,
            blockingReason: blockingReason
        )
    }

    private func buildWindowsInstallerPlan(
        profile: SourceImageProfile,
        windows: WindowsImageProfile,
        toolchain: ToolchainStatus,
        options: WriteOptions
    ) -> WritePlan {
        let targetSystem = profile.preferredTargetSystem
        let partitionScheme: PartitionScheme = switch targetSystem {
        case .uefi:
            .gpt
        case .bios, .dual:
            .mbr
        }

        let installPath = windows.installImageRelativePath?.lowercased()
        let oversizedNonInstall = profile.oversizedPaths.filter { path in
            guard let installPath else { return true }
            return path != installPath
        }

        let payloadMode: WindowsInstallerPayloadMode
        let partitionLayouts: [PartitionLayout]
        let primaryFilesystem: FilesystemType
        var helperRequirements = [
            HelperRequirement(tool: .diskutil, reason: "Prepare and partition the target USB"),
            HelperRequirement(tool: .hdiutil, reason: "Mount the source image"),
        ]
        var postWriteFixups: [PostWriteFixupStep] = []
        let summary: String

        if !oversizedNonInstall.isEmpty {
            payloadMode = .ntfsUefiNtfs
            partitionLayouts = [
                PartitionLayout(name: "UEFI_NTFS", filesystem: .fat32, sizeMiB: 1, description: "Boot bridge partition"),
                PartitionLayout(name: "WININSTALL", filesystem: .ntfs, sizeMiB: nil, description: "NTFS Windows installer payload"),
            ]
            primaryFilesystem = .ntfs
            helperRequirements.append(HelperRequirement(tool: .dd, reason: "Write the UEFI:NTFS helper image"))
            helperRequirements.append(HelperRequirement(tool: .uefiNTFSImage, reason: "Stage the UEFI:NTFS boot bridge image"))
            helperRequirements.append(HelperRequirement(tool: .mkntfs, reason: "Format the payload partition as NTFS"))
            helperRequirements.append(HelperRequirement(tool: .ntfsPopulateHelper, reason: "Populate and verify the NTFS payload partition without macFUSE"))
            helperRequirements.append(HelperRequirement(tool: .ntfsfix, reason: "Run the NTFS finalization pass"))
            summary = "Use the NTFS Windows path with a UEFI helper partition and an NTFS payload partition."
            postWriteFixups.append(.ntfsFinalize)
        } else {
            partitionLayouts = [
                PartitionLayout(name: "WINDOWS", filesystem: .fat32, sizeMiB: nil, description: "Bootable installer payload")
            ]
            primaryFilesystem = .fat32

            if windows.requiresWIMSplit {
                payloadMode = .fat32SplitWim
                summary = "Use FAT32 extraction and split the large Windows install image automatically."
            } else {
                payloadMode = .fat32Extract
                summary = "Use FAT32 extraction for the Windows installer."
            }

            if windows.requiresWIMSplit || windows.needsWindows7EFIFallback {
                helperRequirements.append(HelperRequirement(tool: .wimlibImagex, reason: "Apply the required Windows installer extraction and patching steps"))
            }
        }

        if windows.needsWindows7EFIFallback {
            postWriteFixups.append(.windows7EFIFallback)
        }
        if windows.requiresBIOSWinPEFixup {
            postWriteFixups.append(.biosWinPEFixup)
        }
        postWriteFixups.append(.normalizeSetupBootArtifacts)
        if options.customizationProfile.bypassSecureBootTPMRAMChecks {
            postWriteFixups.append(.injectWindows11BypassArtifacts)
        }
        if windows.hasPantherUnattend {
            postWriteFixups.append(.preservePantherUnattend)
        }
        if windows.prefersPantherCustomization {
            postWriteFixups.append(.injectPantherUnattend)
        } else {
            postWriteFixups.append(.injectAutounattend)
        }

        let blockingReason = toolchain.blockingReason(for: helperRequirements)

        var warnings = profile.notes
        if payloadMode == .ntfsUefiNtfs {
            warnings.append("The source contains Windows payload files that exceed FAT32 limits outside install.wim/install.esd, so the planner switched to the NTFS Windows path.")
        }
        if options.customizationProfile.useMicrosoft2023Bootloaders {
            warnings.append("This build does not bundle alternate Microsoft 2023-signed bootloader assets yet, so that toggle is currently advisory.")
        }

        return WritePlan(
            mediaMode: .windowsInstaller,
            payloadMode: payloadMode,
            partitionScheme: partitionScheme,
            targetSystem: targetSystem,
            primaryFilesystem: primaryFilesystem,
            partitionLayouts: partitionLayouts,
            helperRequirements: helperRequirements,
            postWriteFixups: postWriteFixups,
            verificationMode: .windowsInstallerManifest,
            verificationSteps: [
                "Verify the copied destination manifest against the mounted source image",
                "Allow the planned Windows patch artifacts and split WIM output",
                "Sync all pending writes",
            ],
            warnings: warnings,
            summary: summary,
            isBlocked: blockingReason != nil,
            blockingReason: blockingReason
        )
    }
}
