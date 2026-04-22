import Foundation

struct ImageInspectionService {
    private let mounter = DiskImageMounter()
    private let rawDiskImageService = RawDiskImageService()

    func inspectImage(at sourceURL: URL) async throws -> SourceImageProfile {
        let values = try sourceURL.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
        if values.isDirectory == true {
            return try inspectDirectory(at: sourceURL)
        }

        if RawDiskImageService.hasCompressedExtension(sourceURL),
           RawDiskImageService.compression(for: sourceURL) == nil {
            throw RawDiskImageServiceError.unsupportedCompressedImage
        }

        let format = inferFormat(for: sourceURL)
        let probe = try ImageBinaryProbeService().probeFile(at: sourceURL, declaredFormat: format)
        let compressedSize = values.fileSize.map(Int64.init) ?? 0
        let size = if format == .dd {
            await rawDiskImageService.logicalSize(for: sourceURL) ?? compressedSize
        } else {
            compressedSize
        }

        switch format {
        case .iso, .udfISO, .dmg:
            return try await inspectMountedImage(
                sourceURL: sourceURL,
                format: format,
                size: size,
                isoHybridStyle: probe.isoHybridStyle,
                probe: probe
            )
        case .wim, .esd:
            return inspectStandaloneWIM(sourceURL: sourceURL, format: format, size: size, probe: probe)
        case .vhd, .vhdx:
            let classification = classify(
                sourceURL: sourceURL,
                probe: probe,
                volumeName: nil,
                bootArtifacts: [],
                hasEFI: false,
                hasBIOS: false,
                layoutHints: .empty
            )
            return SourceImageProfile(
                sourceURL: sourceURL,
                format: format,
                size: size,
                detectedVolumeName: nil,
                hasEFI: false,
                hasBIOS: false,
                oversizedPaths: [],
                bootArtifactPaths: [],
                supportedMediaModes: [.driveRestore],
                notes: ["Restore support for this image type depends on helper availability."],
                windows: nil,
                supportsDOSBoot: false,
                supportsLinuxBoot: false,
                supportsPersistence: false,
                persistenceFlavor: .none,
                secureBootValidationCandidate: false,
                downloadFamily: nil,
                applianceProfile: applianceProfile(from: classification),
                classification: classification
            )
        case .dd:
            var notes: [String] = []
            if let preparationNote = rawDiskImageService.preparationNote(for: sourceURL) {
                notes.append(preparationNote)
            }
            let classification = classify(
                sourceURL: sourceURL,
                probe: probe,
                volumeName: nil,
                bootArtifacts: [],
                hasEFI: false,
                hasBIOS: false,
                layoutHints: .empty
            )
            return SourceImageProfile(
                sourceURL: sourceURL,
                format: format,
                size: size,
                detectedVolumeName: nil,
                hasEFI: false,
                hasBIOS: false,
                oversizedPaths: [],
                bootArtifactPaths: [],
                supportedMediaModes: [.directImage, .driveRestore],
                notes: notes,
                windows: nil,
                supportsDOSBoot: false,
                supportsLinuxBoot: false,
                supportsPersistence: false,
                persistenceFlavor: .none,
                secureBootValidationCandidate: false,
                downloadFamily: nil,
                applianceProfile: applianceProfile(from: classification),
                classification: classification
            )
        case .unknown:
            let classification = classify(
                sourceURL: sourceURL,
                probe: probe,
                volumeName: nil,
                bootArtifacts: [],
                hasEFI: false,
                hasBIOS: false,
                layoutHints: .empty
            )
            return SourceImageProfile(
                sourceURL: sourceURL,
                format: .unknown,
                size: size,
                detectedVolumeName: nil,
                hasEFI: false,
                hasBIOS: false,
                oversizedPaths: [],
                bootArtifactPaths: [],
                supportedMediaModes: [.directImage],
                notes: ["The image type is unknown, so the planner will use the safest generic path."],
                windows: nil,
                supportsDOSBoot: false,
                supportsLinuxBoot: false,
                supportsPersistence: false,
                persistenceFlavor: .none,
                secureBootValidationCandidate: false,
                downloadFamily: nil,
                applianceProfile: applianceProfile(from: classification),
                classification: classification
            )
        }
    }

    func inspectDirectory(at directoryURL: URL) throws -> SourceImageProfile {
        let size = try directorySize(at: directoryURL)
        let probe = ImageBinaryProbe.synthetic(sourceURL: directoryURL, fileSize: size, declaredFormat: .unknown)
        return try inspectMountedRoot(
            directoryURL,
            sourceURL: directoryURL,
            format: .unknown,
            size: size,
            volumeName: directoryURL.lastPathComponent,
            isoHybridStyle: .notApplicable,
            probe: probe
        )
    }

    private func inspectMountedImage(
        sourceURL: URL,
        format: SourceImageFormat,
        size: Int64,
        isoHybridStyle: ISOHybridStyle,
        probe: ImageBinaryProbe
    ) async throws -> SourceImageProfile {
        let mounted = try await mounter.mountImage(at: sourceURL)

        do {
            let profile = try inspectMountedRoot(
                mounted.mountPoint,
                sourceURL: sourceURL,
                format: format,
                size: size,
                volumeName: mounted.volumeName,
                isoHybridStyle: isoHybridStyle,
                probe: probe
            )
            try await mounter.detach(mounted)
            return profile
        } catch {
            try? await mounter.detach(mounted)
            throw error
        }
    }

    private func inspectMountedRoot(
        _ root: URL,
        sourceURL: URL,
        format: SourceImageFormat,
        size: Int64,
        volumeName: String,
        isoHybridStyle: ISOHybridStyle,
        probe: ImageBinaryProbe
    ) throws -> SourceImageProfile {
        let fileManager = FileManager.default
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .fileSizeKey]
        let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])

        var hasEFI = false
        var hasBIOS = false
        var oversizedPaths: [String] = []
        var bootArtifacts: [String] = []
        var installImagePath: String?
        var installImageSize: Int64?
        var hasBootWIM = false
        var hasPantherUnattend = false
        var foundStandaloneWinPEArtifact = false
        var hasCommandCom = false
        var hasKernelSys = false
        var hasUEFIShell = false
        var hasFreeBSDLoader = false
        var supportsLinuxBoot = false
        var persistenceFlavor: LinuxPersistenceFlavor = .none
        var linuxDistribution: LinuxDistribution = .none
        var hasCanonicalEFIBootLoader = false
        var hasAlternateEFIBootLoader = false
        var hasBootGrubConfig = false
        var hasRootGrubConfig = false
        var hasIsolinuxConfig = false
        var hasSyslinuxConfig = false
        var notes: [String] = []
        var relativePathsSet = Set<String>()
        var topLevelNames = Set<String>()

        while let item = enumerator?.nextObject() as? URL {
            let values = try item.resourceValues(forKeys: keys)
            guard values.isDirectory != true else {
                continue
            }

            let relativePath = relativePath(for: item, under: root).lowercased()
            relativePathsSet.insert(relativePath)
            if let firstComponent = relativePath.split(separator: "/").first {
                topLevelNames.insert(String(firstComponent))
            }
            let fileSize = Int64(values.fileSize ?? 0)

            if fileSize > SourceImageProfile.fat32MaximumFileSize {
                oversizedPaths.append(relativePath)
            }

            if relativePath == "efi/boot/bootx64.efi"
                || relativePath == "efi/boot/bootia32.efi"
                || relativePath == "efi/boot/bootaa64.efi" {
                hasEFI = true
                hasCanonicalEFIBootLoader = true
                bootArtifacts.append(relativePath)
            } else if relativePath.hasPrefix("efi/")
                && relativePath.hasSuffix(".efi")
                && (relativePath.contains("grub")
                    || relativePath.contains("shim")
                    || relativePath.contains("boot")) {
                hasEFI = true
                hasAlternateEFIBootLoader = true
                bootArtifacts.append(relativePath)
            }

            if relativePath == "bootmgr"
                || relativePath == "boot/etfsboot.com"
                || relativePath.hasSuffix("/isolinux.bin")
                || relativePath.hasSuffix("/ldlinux.c32")
                || relativePath.contains("/grub/i386-pc/")
                || relativePath.contains("/syslinux/") {
                hasBIOS = true
                bootArtifacts.append(relativePath)
            }

            if relativePath == "boot/grub/grub.cfg"
                || relativePath == "boot/grub/loopback.cfg"
                || relativePath == "grub/grub.cfg"
                || relativePath == "isolinux/isolinux.cfg"
                || relativePath == "isolinux/txt.cfg"
                || relativePath == "isolinux/live.cfg"
                || relativePath == "syslinux/syslinux.cfg"
                || relativePath == "syslinux/txt.cfg"
                || relativePath == "syslinux/live.cfg"
                || relativePath.hasPrefix("loader/entries/") {
                bootArtifacts.append(relativePath)
                supportsLinuxBoot = true
            }
            if relativePath == "boot/grub/grub.cfg" || relativePath == "boot/grub/loopback.cfg" {
                hasBootGrubConfig = true
            }
            if relativePath == "grub/grub.cfg" {
                hasRootGrubConfig = true
            }
            if relativePath == "isolinux/isolinux.cfg" || relativePath == "isolinux/txt.cfg" || relativePath == "isolinux/live.cfg" {
                hasIsolinuxConfig = true
            }
            if relativePath == "syslinux/syslinux.cfg" || relativePath == "syslinux/txt.cfg" || relativePath == "syslinux/live.cfg" {
                hasSyslinuxConfig = true
            }

            if relativePath == "command.com" {
                hasCommandCom = true
            }

            if relativePath == "kernel.sys" {
                hasKernelSys = true
            }

            if relativePath.hasSuffix("shellx64.efi")
                || relativePath.hasSuffix("shellaa64.efi")
                || relativePath == "startup.nsh" {
                hasUEFIShell = true
            }

            if relativePath == "boot/loader.efi" || relativePath == "efi/boot/loader.efi" {
                hasEFI = true
                bootArtifacts.append(relativePath)
                hasFreeBSDLoader = true
            } else if relativePath == "boot/loader"
                || relativePath == "boot/defaults/loader.conf" {
                hasFreeBSDLoader = true
            }

            if relativePath.hasPrefix("casper/") {
                persistenceFlavor = .casper
                supportsLinuxBoot = true
                linuxDistribution = .ubuntu
            } else if persistenceFlavor == .none && relativePath.hasPrefix("live/") {
                persistenceFlavor = .debian
                supportsLinuxBoot = true
                if linuxDistribution == .none {
                    linuxDistribution = .debian
                }
            }

            if relativePath.hasPrefix("boot/grub/")
                || relativePath.hasPrefix("grub/")
                || relativePath.hasPrefix("isolinux/")
                || relativePath.hasPrefix("syslinux/")
                || relativePath.hasPrefix("loader/entries/")
                || relativePath.hasSuffix(".squashfs")
                || relativePath.hasSuffix(".sfs")
                || relativePath.contains("/vmlinuz")
                || relativePath.contains("/initrd")
                || relativePath == ".treeinfo" {
                supportsLinuxBoot = true
            }
            if relativePath == ".treeinfo" {
                linuxDistribution = .fedora
            }
            if relativePath.hasPrefix("arch/") {
                linuxDistribution = .arch
            }
            if relativePath.contains("kali") {
                linuxDistribution = .kali
            }

            if isLinuxConfigCandidate(relativePath),
               fileSize > 0,
               fileSize <= 1_048_576,
               let contents = try? String(contentsOf: item, encoding: .utf8).lowercased() {
                if contents.contains("boot=casper")
                    || contents.contains("file=/cdrom/preseed")
                    || contents.contains("/casper/vmlinuz") {
                    persistenceFlavor = .casper
                    supportsLinuxBoot = true
                    linuxDistribution = .ubuntu
                } else if persistenceFlavor == .none && contents.contains("boot=live") {
                    persistenceFlavor = .debian
                    supportsLinuxBoot = true
                    if contents.contains("kali") {
                        linuxDistribution = .kali
                    } else if linuxDistribution == .none {
                        linuxDistribution = .debian
                    }
                } else if contents.contains("linux ")
                    || contents.contains("linuxefi ")
                    || contents.contains("initrd")
                    || contents.contains("search --label") {
                    supportsLinuxBoot = true
                }
                if contents.contains("archisolabel=") {
                    linuxDistribution = .arch
                }
                if contents.contains("rd.live.image") || contents.contains("inst.stage2=") {
                    linuxDistribution = .fedora
                }
                if contents.contains("kali") {
                    linuxDistribution = .kali
                } else if linuxDistribution == .none && contents.contains("debian") {
                    linuxDistribution = .debian
                }
            }

            if relativePath == "sources/install.wim" || relativePath == "sources/install.esd" {
                installImagePath = relativePath
                installImageSize = fileSize
            }

            if relativePath == "sources/boot.wim" {
                hasBootWIM = true
            }

            if relativePath == "sources/$oem$/$$/panther/unattend.xml" || relativePath == "autounattend.xml" {
                hasPantherUnattend = true
            }

            if relativePath.hasSuffix("winpe.wim") {
                foundStandaloneWinPEArtifact = true
            }
        }

        let supportsWindowsInstaller = installImagePath != nil
        let isWinPE = foundStandaloneWinPEArtifact || (hasBootWIM && installImagePath == nil)
        let windowsProfile = installImagePath.map { path in
            WindowsImageProfile(
                installImageRelativePath: path,
                installImageSize: installImageSize,
                hasBootWIM: hasBootWIM,
                hasPantherUnattend: hasPantherUnattend,
                isWinPE: isWinPE,
                needsWindows7EFIFallback: !hasEFI && hasBootWIM,
                requiresWIMSplit: (installImageSize ?? 0) > SourceImageProfile.fat32MaximumFileSize,
                requiresBIOSWinPEFixup: isWinPE && hasBIOS,
                prefersPantherCustomization: !isWinPE
            )
        }
        let supportsDOSBoot = hasCommandCom && hasKernelSys
        let supportsPersistence = persistenceFlavor != .none
        let secureBootValidationCandidate = hasEFI || hasUEFIShell
        if supportsLinuxBoot && linuxDistribution == .none {
            linuxDistribution = .generic
        }
        let linuxBootFixes = detectLinuxBootFixes(
            supportsLinuxBoot: supportsLinuxBoot,
            isoHybridStyle: isoHybridStyle,
            detectedVolumeName: volumeName,
            hasCanonicalEFIBootLoader: hasCanonicalEFIBootLoader,
            hasAlternateEFIBootLoader: hasAlternateEFIBootLoader,
            hasBootGrubConfig: hasBootGrubConfig,
            hasRootGrubConfig: hasRootGrubConfig,
            hasIsolinuxConfig: hasIsolinuxConfig,
            hasSyslinuxConfig: hasSyslinuxConfig
        )
        let downloadFamily: DownloadCatalogFamily? = if supportsWindowsInstaller {
            .windows
        } else if hasUEFIShell {
            .uefiShell
        } else {
            nil
        }
        let classification = classify(
            sourceURL: sourceURL,
            probe: probe,
            volumeName: volumeName,
            bootArtifacts: bootArtifacts + (hasFreeBSDLoader ? ["boot/loader.efi"] : []),
            hasEFI: hasEFI,
            hasBIOS: hasBIOS,
            layoutHints: ImageLayoutHints(
                volumeName: volumeName,
                relativePaths: relativePathsSet,
                topLevelNames: topLevelNames
            )
        )
        let applianceProfile = applianceProfile(from: classification)

        if supportsWindowsInstaller && !hasEFI && hasBootWIM {
            notes.append("The installer looks like it may need the Windows 7 EFI fallback patch.")
        }
        if hasPantherUnattend {
            notes.append("An existing unattended configuration was found and should be preserved.")
        }
        if supportsDOSBoot {
            notes.append("Bundled FreeDOS system files were detected.")
            hasBIOS = true
        }
        if supportsLinuxBoot {
            let distro = linuxDistribution.displayName ?? "Linux"
            notes.append("\(distro) boot media was detected.")
        }
        if let hybridLabel = isoHybridStyle.shortLabel, supportsLinuxBoot {
            notes.append("\(hybridLabel) detected.")
        }
        if supportsPersistence {
            let distro = linuxDistribution == .kali ? "Kali" : (linuxDistribution.displayName ?? "Linux")
            notes.append("\(distro) persistence support was detected.")
        }
        if !linuxBootFixes.isEmpty {
            notes.append("USB boot fixups will be applied for common distro quirks.")
        }
        if hasUEFIShell {
            notes.append("UEFI Shell boot files were detected.")
        }
        if let applianceProfile {
            notes.append("Detected appliance profile: \(applianceProfile.displayName).")
        }

        let supportedModes: [MediaMode]
        if supportsWindowsInstaller {
            supportedModes = [.windowsInstaller]
        } else {
            supportedModes = [.directImage]
        }

        return SourceImageProfile(
            sourceURL: sourceURL,
            format: format,
            size: size,
            detectedVolumeName: volumeName,
            hasEFI: hasEFI,
            hasBIOS: hasBIOS,
            oversizedPaths: oversizedPaths.sorted(),
            bootArtifactPaths: bootArtifacts.sorted(),
            supportedMediaModes: supportedModes,
            notes: notes,
            windows: windowsProfile,
            supportsDOSBoot: supportsDOSBoot,
            supportsLinuxBoot: supportsLinuxBoot,
            supportsPersistence: supportsPersistence,
            persistenceFlavor: persistenceFlavor,
            secureBootValidationCandidate: secureBootValidationCandidate,
            downloadFamily: downloadFamily,
            isoHybridStyle: isoHybridStyle,
            linuxDistribution: linuxDistribution,
            linuxBootFixes: linuxBootFixes,
            applianceProfile: applianceProfile,
            classification: classification
        )
    }

    private func detectLinuxBootFixes(
        supportsLinuxBoot: Bool,
        isoHybridStyle: ISOHybridStyle,
        detectedVolumeName: String,
        hasCanonicalEFIBootLoader: Bool,
        hasAlternateEFIBootLoader: Bool,
        hasBootGrubConfig: Bool,
        hasRootGrubConfig: Bool,
        hasIsolinuxConfig: Bool,
        hasSyslinuxConfig: Bool
    ) -> [LinuxBootFix] {
        guard supportsLinuxBoot else {
            return []
        }

        var fixes: [LinuxBootFix] = []
        if hasAlternateEFIBootLoader && !hasCanonicalEFIBootLoader {
            fixes.append(.normalizeEFIBootFiles)
        }
        if hasBootGrubConfig != hasRootGrubConfig {
            fixes.append(.mirrorGRUBConfig)
        }
        if hasIsolinuxConfig != hasSyslinuxConfig {
            fixes.append(.mirrorSyslinuxConfig)
        }
        if !detectedVolumeName.isEmpty && isoHybridStyle != .notApplicable {
            fixes.append(.rewriteVolumeLabels)
        }
        return fixes
    }

    private func inspectStandaloneWIM(sourceURL: URL, format: SourceImageFormat, size: Int64, probe: ImageBinaryProbe) -> SourceImageProfile {
        let relativeName = sourceURL.lastPathComponent.lowercased()
        let windows = WindowsImageProfile(
            installImageRelativePath: relativeName,
            installImageSize: size,
            hasBootWIM: false,
            hasPantherUnattend: false,
            isWinPE: false,
            needsWindows7EFIFallback: false,
            requiresWIMSplit: size > SourceImageProfile.fat32MaximumFileSize,
            requiresBIOSWinPEFixup: false,
            prefersPantherCustomization: false
        )
        let classification = classify(
            sourceURL: sourceURL,
            probe: probe,
            volumeName: nil,
            bootArtifacts: [],
            hasEFI: false,
            hasBIOS: false,
            layoutHints: .empty
        )

        return SourceImageProfile(
            sourceURL: sourceURL,
            format: format,
            size: size,
            detectedVolumeName: nil,
            hasEFI: false,
            hasBIOS: false,
            oversizedPaths: size > SourceImageProfile.fat32MaximumFileSize ? [relativeName] : [],
            bootArtifactPaths: [],
            supportedMediaModes: [],
            notes: ["Standalone WIM/ESD files are not part of the current product scope."],
            windows: windows,
            supportsDOSBoot: false,
            supportsLinuxBoot: false,
            supportsPersistence: false,
            persistenceFlavor: .none,
            secureBootValidationCandidate: false,
            downloadFamily: nil,
            applianceProfile: applianceProfile(from: classification),
            classification: classification
        )
    }

    private func inferFormat(for sourceURL: URL) -> SourceImageFormat {
        if RawDiskImageService.isSupportedRawImage(sourceURL) {
            return .dd
        }

        switch sourceURL.pathExtension.lowercased() {
        case "iso":
            return .iso
        case "udf":
            return .udfISO
        case "dmg":
            return .dmg
        case "vhd":
            return .vhd
        case "vhdx":
            return .vhdx
        case "wim":
            return .wim
        case "esd":
            return .esd
        default:
            return .unknown
        }
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

    private func directorySize(at root: URL) throws -> Int64 {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .fileSizeKey]
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])
        var total: Int64 = 0

        while let item = enumerator?.nextObject() as? URL {
            let values = try item.resourceValues(forKeys: keys)
            guard values.isDirectory != true else {
                continue
            }
            total += Int64(values.fileSize ?? 0)
        }

        return total
    }

    private func classify(
        sourceURL: URL,
        probe: ImageBinaryProbe,
        volumeName: String?,
        bootArtifacts: [String],
        hasEFI: Bool,
        hasBIOS: Bool,
        layoutHints: ImageLayoutHints
    ) -> ImageClassificationResult {
        let context = ImageClassificationContext(
            sourceURL: sourceURL,
            probe: probe,
            layoutHints: ImageLayoutHints(
                volumeName: volumeName ?? layoutHints.volumeName,
                relativePaths: layoutHints.relativePaths,
                topLevelNames: layoutHints.topLevelNames
            ),
            bootArtifactPaths: Set(bootArtifacts.map { $0.lowercased() }),
            hasEFI: hasEFI,
            hasBIOS: hasBIOS
        )
        return ImageClassifier().classify(context)
    }

    private func applianceProfile(from classification: ImageClassificationResult?) -> ApplianceProfile? {
        switch classification?.matchedVendorProfile {
        case .proxmoxVE:
            return .proxmoxInstaller
        case .trueNAS:
            return .trueNASInstaller
        case .openWrt:
            return .openWrtImage
        case .opnSense, .pfSense, .none:
            return nil
        }
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
