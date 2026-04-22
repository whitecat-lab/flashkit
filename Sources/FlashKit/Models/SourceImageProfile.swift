import Foundation

enum SourceImageFormat: String, CaseIterable, Sendable {
    case iso
    case udfISO = "udf-iso"
    case dmg
    case dd
    case vhd
    case vhdx
    case wim
    case esd
    case unknown
}

enum MediaMode: String, CaseIterable, Sendable {
    case windowsInstaller = "Windows installer"
    case directImage = "Direct image"
    case driveCapture = "Drive capture"
    case driveRestore = "Drive restore"
}

enum LinuxPersistenceFlavor: String, Sendable {
    case casper
    case debian
    case none

    var kernelArgument: String? {
        switch self {
        case .casper:
            return "persistent"
        case .debian:
            return "persistence"
        case .none:
            return nil
        }
    }

    var partitionLabel: String? {
        switch self {
        case .casper:
            return "casper-rw"
        case .debian:
            return "persistence"
        case .none:
            return nil
        }
    }
}

enum ISOHybridStyle: String, Sendable {
    case notApplicable
    case nonHybrid
    case hybridMBR
    case hybridGPT
    case hybridMBRAndGPT

    var isHybrid: Bool {
        switch self {
        case .hybridMBR, .hybridGPT, .hybridMBRAndGPT:
            return true
        case .notApplicable, .nonHybrid:
            return false
        }
    }

    var shortLabel: String? {
        switch self {
        case .notApplicable:
            return nil
        case .nonHybrid:
            return "Non-hybrid ISO"
        case .hybridMBR:
            return "Hybrid ISO (MBR)"
        case .hybridGPT:
            return "Hybrid ISO (GPT)"
        case .hybridMBRAndGPT:
            return "Hybrid ISO (MBR + GPT)"
        }
    }
}

enum LinuxDistribution: String, Sendable {
    case none
    case ubuntu
    case kali
    case debian
    case fedora
    case arch
    case generic

    var displayName: String? {
        switch self {
        case .none:
            return nil
        case .ubuntu:
            return "Ubuntu-family"
        case .kali:
            return "Kali"
        case .debian:
            return "Debian-family"
        case .fedora:
            return "Fedora-family"
        case .arch:
            return "Arch-family"
        case .generic:
            return "Linux"
        }
    }

    var preferredVolumeLabel: String? {
        switch self {
        case .none:
            return nil
        case .ubuntu:
            return "UBUNTU"
        case .kali:
            return "KALI"
        case .debian:
            return "DEBIAN"
        case .fedora:
            return "FEDORA"
        case .arch:
            return "ARCH"
        case .generic:
            return "LINUX"
        }
    }
}

enum LinuxBootFix: String, Hashable, Sendable {
    case normalizeEFIBootFiles
    case mirrorGRUBConfig
    case mirrorSyslinuxConfig
    case rewriteVolumeLabels

    var description: String {
        switch self {
        case .normalizeEFIBootFiles:
            return "Normalize EFI bootloader fallback paths"
        case .mirrorGRUBConfig:
            return "Mirror GRUB config into common boot paths"
        case .mirrorSyslinuxConfig:
            return "Mirror syslinux/isolinux config into expected paths"
        case .rewriteVolumeLabels:
            return "Rewrite volume-label boot references for USB media"
        }
    }
}

enum ApplianceProfile: String, Sendable {
    case proxmoxInstaller
    case trueNASInstaller
    case openWrtImage

    var displayName: String {
        switch self {
        case .proxmoxInstaller:
            return "Proxmox installer"
        case .trueNASInstaller:
            return "TrueNAS installer"
        case .openWrtImage:
            return "OpenWrt image"
        }
    }

    var automaticBehaviorSummary: String {
        switch self {
        case .proxmoxInstaller:
            return "Appliance mode will write the hybrid installer directly and verify EFI boot files."
        case .trueNASInstaller:
            return "Appliance mode will preserve the installer partition layout and validate the expected boot partitions."
        case .openWrtImage:
            return "Appliance mode will raw-write the image without touching partitions or filesystems."
        }
    }

    var recommendedVolumeLabel: String? {
        switch self {
        case .proxmoxInstaller:
            return "PROXMOX"
        case .trueNASInstaller:
            return "TRUENAS"
        case .openWrtImage:
            return "OPENWRT"
        }
    }
}

struct WindowsImageProfile: Sendable {
    let installImageRelativePath: String?
    let installImageSize: Int64?
    let hasBootWIM: Bool
    let hasPantherUnattend: Bool
    let isWinPE: Bool
    let needsWindows7EFIFallback: Bool
    let requiresWIMSplit: Bool
    let requiresBIOSWinPEFixup: Bool
    let prefersPantherCustomization: Bool
}

struct SourceImageProfile: Sendable {
    static let fat32MaximumFileSize: Int64 = 4_294_967_295

    let sourceURL: URL
    let format: SourceImageFormat
    let size: Int64
    let detectedVolumeName: String?
    let hasEFI: Bool
    let hasBIOS: Bool
    let oversizedPaths: [String]
    let bootArtifactPaths: [String]
    let supportedMediaModes: [MediaMode]
    let notes: [String]
    let windows: WindowsImageProfile?
    let supportsDOSBoot: Bool
    let supportsLinuxBoot: Bool
    let supportsPersistence: Bool
    let persistenceFlavor: LinuxPersistenceFlavor
    let secureBootValidationCandidate: Bool
    let downloadFamily: DownloadCatalogFamily?
    let isoHybridStyle: ISOHybridStyle
    let linuxDistribution: LinuxDistribution
    let linuxBootFixes: [LinuxBootFix]
    let applianceProfile: ApplianceProfile?
    let classification: ImageClassificationResult?

    init(
        sourceURL: URL,
        format: SourceImageFormat,
        size: Int64,
        detectedVolumeName: String?,
        hasEFI: Bool,
        hasBIOS: Bool,
        oversizedPaths: [String],
        bootArtifactPaths: [String],
        supportedMediaModes: [MediaMode],
        notes: [String],
        windows: WindowsImageProfile?,
        supportsDOSBoot: Bool,
        supportsLinuxBoot: Bool,
        supportsPersistence: Bool,
        persistenceFlavor: LinuxPersistenceFlavor,
        secureBootValidationCandidate: Bool,
        downloadFamily: DownloadCatalogFamily?,
        isoHybridStyle: ISOHybridStyle = .notApplicable,
        linuxDistribution: LinuxDistribution = .none,
        linuxBootFixes: [LinuxBootFix] = [],
        applianceProfile: ApplianceProfile? = nil,
        classification: ImageClassificationResult? = nil
    ) {
        self.sourceURL = sourceURL
        self.format = format
        self.size = size
        self.detectedVolumeName = detectedVolumeName
        self.hasEFI = hasEFI
        self.hasBIOS = hasBIOS
        self.oversizedPaths = oversizedPaths
        self.bootArtifactPaths = bootArtifactPaths
        self.supportedMediaModes = supportedMediaModes
        self.notes = notes
        self.windows = windows
        self.supportsDOSBoot = supportsDOSBoot
        self.supportsLinuxBoot = supportsLinuxBoot
        self.supportsPersistence = supportsPersistence
        self.persistenceFlavor = persistenceFlavor
        self.secureBootValidationCandidate = secureBootValidationCandidate
        self.downloadFamily = downloadFamily
        self.isoHybridStyle = isoHybridStyle
        self.linuxDistribution = linuxDistribution
        self.linuxBootFixes = linuxBootFixes
        self.applianceProfile = applianceProfile
        self.classification = classification
    }

    var displayName: String {
        sourceURL.lastPathComponent
    }

    var isWindowsInstaller: Bool {
        windows != nil && supportedMediaModes.contains(.windowsInstaller)
    }

    var isFreeDOSMedia: Bool {
        supportsDOSBoot && downloadFamily == nil
    }

    var isUEFIShellImage: Bool {
        downloadFamily == .uefiShell
    }

    var isLinuxBootImage: Bool {
        supportsLinuxBoot && !isWindowsInstaller && !isFreeDOSMedia && !isUEFIShellImage
    }

    var requiresLinuxExtractionRebuild: Bool {
        guard isLinuxBootImage else {
            return false
        }

        if supportsPersistence {
            return true
        }

        if !linuxBootFixes.isEmpty {
            return true
        }

        return !isoHybridStyle.isHybrid
    }

    var requiresBootAssetsSource: Bool {
        format == .wim || format == .esd
    }

    var recommendedVolumeLabel: String {
        VolumeLabelFormatter.sanitizedFATLabel(preferredVolumeLabelCandidate)
    }

    var hasCanonicalEFIBootFallback: Bool {
        let normalizedArtifacts = Set(bootArtifactPaths.map { $0.lowercased() })
        return normalizedArtifacts.contains("efi/boot/bootx64.efi")
            || normalizedArtifacts.contains("efi/boot/bootaa64.efi")
            || normalizedArtifacts.contains("efi/boot/bootia32.efi")
    }

    var preferredTargetSystem: TargetSystem {
        switch (hasEFI, hasBIOS) {
        case (true, true):
            return .dual
        case (true, false):
            return .uefi
        case (false, true):
            return .bios
        case (false, false):
            return .dual
        }
    }

    var preferredRebuildPartitionScheme: PartitionScheme {
        if applianceProfile == .trueNASInstaller && hasEFI {
            return .gpt
        }

        switch isoHybridStyle {
        case .hybridGPT:
            return .gpt
        case .hybridMBR:
            return .mbr
        case .hybridMBRAndGPT:
            return hasEFI && !hasBIOS ? .gpt : .mbr
        case .notApplicable, .nonHybrid:
            switch preferredTargetSystem {
            case .uefi:
                return .gpt
            case .bios, .dual:
                return .mbr
            }
        }
    }

    var requiresFAT32FirmwareBoot: Bool {
        if isFreeDOSMedia || isUEFIShellImage {
            return true
        }

        if isLinuxBootImage {
            return hasEFI || supportsPersistence || !isoHybridStyle.isHybrid
        }

        if applianceProfile == .trueNASInstaller {
            return hasEFI
        }

        if applianceProfile == .proxmoxInstaller {
            return hasEFI && !isoHybridStyle.isHybrid
        }

        return false
    }

    var requiresEFIRepairOnExtractedMedia: Bool {
        if isUEFIShellImage {
            return true
        }

        if applianceProfile == .trueNASInstaller && hasEFI {
            return !hasCanonicalEFIBootFallback
        }

        if isLinuxBootImage {
            return !hasCanonicalEFIBootFallback || linuxBootFixes.contains(.normalizeEFIBootFiles)
        }

        return hasEFI && !hasCanonicalEFIBootFallback
    }

    var headline: String {
        if let applianceProfile {
            return "Detected: \(applianceProfile.displayName)"
        }

        if isWindowsInstaller {
            return "Windows media detected"
        }

        if isFreeDOSMedia {
            return "FreeDOS boot media detected"
        }

        if isUEFIShellImage {
            return "UEFI Shell media detected"
        }

        if isLinuxBootImage {
            return "Linux boot media detected"
        }

        switch format {
        case .vhd, .vhdx:
            return "Drive image detected"
        case .wim, .esd:
            return "Windows deployment image detected"
        case .iso, .udfISO, .dmg, .dd:
            return hasEFI || hasBIOS ? "Bootable image detected" : "Disk image detected"
        case .unknown:
            return "Source image detected"
        }
    }

    var summaryLine: String {
        if let applianceProfile {
            return applianceProfile.automaticBehaviorSummary
        }

        if isWindowsInstaller {
            if windows?.requiresWIMSplit == true {
                return "Windows installer with a large install image detected."
            }

            return "Windows installer detected and ready for automatic planning."
        }

        if isFreeDOSMedia {
            return "Create a bootable FreeDOS USB from the bundled FreeDOS system files."
        }

        if supportsPersistence, let flavor = persistenceFlavor.kernelArgument {
            let distro = linuxDistribution.displayName ?? "Linux"
            return "This \(distro) image supports a \(flavor) persistence partition when rebuilt for USB media."
        }

        if isLinuxBootImage {
            if requiresLinuxExtractionRebuild {
                let distro = linuxDistribution.displayName ?? "Linux"
                return "This \(distro) image will be extracted and rebuilt for USB boot compatibility."
            }

            if let hybridLabel = isoHybridStyle.shortLabel {
                return "\(hybridLabel) detected. The planner can preserve the original boot layout with a direct write."
            }

            return "This Linux image can be written directly to preserve its original boot layout."
        }

        if isUEFIShellImage {
            return "This image contains UEFI Shell boot files and can be written as bootable shell media."
        }

        if format == .wim || format == .esd {
            return "Select Windows setup boot assets to rebuild this standalone install image into bootable installer media."
        }

        if supportedMediaModes.contains(.driveRestore) {
            return "This source can be restored back onto a removable drive."
        }

        if supportedMediaModes.contains(.directImage) {
            return "This source can be written as a direct disk image."
        }

        return "The source was inspected successfully."
    }

    var warningSummary: String? {
        if let applianceProfile, applianceProfile == .openWrtImage {
            return "OpenWrt images are written raw. FlashKit will not repartition, extract, or format the target USB."
        }

        if let windows, windows.needsWindows7EFIFallback {
            return "EFI boot files were not found directly on the image. A Windows 7-style EFI fallback patch will be required."
        }

        if let windows, windows.requiresBIOSWinPEFixup {
            return "The source looks like BIOS-targeted WinPE media and will require legacy setup loader fixups."
        }

        if requiresBootAssetsSource {
            return "Standalone WIM/ESD files need Windows setup boot assets before they can become bootable installer media."
        }

        if !oversizedPaths.isEmpty && windows?.requiresWIMSplit != true {
            return "The source contains files too large for FAT32. The planner will switch to the UEFI helper path when possible."
        }

        if supportsPersistence && !oversizedPaths.isEmpty {
            return "Linux persistence is only available when the live image payload fits on a FAT32 boot partition."
        }

        if requiresEFIRepairOnExtractedMedia && (isLinuxBootImage || isUEFIShellImage || applianceProfile != nil) {
            return "FlashKit will rebuild missing EFI fallback boot files when the media is extracted for USB firmware compatibility."
        }

        if isLinuxBootImage && !isoHybridStyle.isHybrid {
            return "This is a non-hybrid Linux ISO, so the planner will extract and rebuild it instead of writing it raw."
        }

        if isLinuxBootImage && !linuxBootFixes.isEmpty {
            let fix = linuxBootFixes.first?.description ?? "Linux boot fixups"
            return "The planner will apply Linux USB boot fixes: \(fix)."
        }

        return notes.first
    }

    func mergedWithBootAssets(_ bootAssets: SourceImageProfile?) -> SourceImageProfile? {
        guard requiresBootAssetsSource, let bootAssets else {
            return nil
        }

        guard bootAssets.hasEFI || bootAssets.hasBIOS || bootAssets.windows?.hasBootWIM == true else {
            return nil
        }

        let installFilename = format == .esd ? "install.esd" : "install.wim"
        let existingWindows = bootAssets.windows

        return SourceImageProfile(
            sourceURL: sourceURL,
            format: format,
            size: size,
            detectedVolumeName: bootAssets.detectedVolumeName ?? sourceURL.deletingPathExtension().lastPathComponent,
            hasEFI: bootAssets.hasEFI,
            hasBIOS: bootAssets.hasBIOS,
            oversizedPaths: size > Self.fat32MaximumFileSize ? ["sources/\(installFilename)"] : [],
            bootArtifactPaths: bootAssets.bootArtifactPaths,
            supportedMediaModes: [.windowsInstaller],
            notes: bootAssets.notes + ["Standalone \(format.rawValue.uppercased()) will be rebuilt with the selected Windows setup boot assets."],
            windows: WindowsImageProfile(
                installImageRelativePath: "sources/\(installFilename)",
                installImageSize: size,
                hasBootWIM: existingWindows?.hasBootWIM ?? false,
                hasPantherUnattend: existingWindows?.hasPantherUnattend ?? false,
                isWinPE: existingWindows?.isWinPE ?? false,
                needsWindows7EFIFallback: existingWindows?.needsWindows7EFIFallback ?? false,
                requiresWIMSplit: size > Self.fat32MaximumFileSize,
                requiresBIOSWinPEFixup: existingWindows?.requiresBIOSWinPEFixup ?? false,
                prefersPantherCustomization: existingWindows?.prefersPantherCustomization ?? true
            ),
            supportsDOSBoot: false,
            supportsLinuxBoot: false,
            supportsPersistence: false,
            persistenceFlavor: .none,
            secureBootValidationCandidate: bootAssets.secureBootValidationCandidate,
            downloadFamily: .windows,
            classification: bootAssets.classification
        )
    }

    private var preferredVolumeLabelCandidate: String {
        if let applianceLabel = applianceProfile?.recommendedVolumeLabel {
            return applianceLabel
        }

        if isWindowsInstaller || downloadFamily == .windows || requiresBootAssetsSource {
            return preferredWindowsVolumeLabel
        }

        if isFreeDOSMedia {
            return "FREEDOS"
        }

        if isUEFIShellImage {
            return "UEFISHELL"
        }

        if isLinuxBootImage {
            return linuxDistribution.preferredVolumeLabel
                ?? meaningfulDetectedVolumeName
                ?? derivedFilenameStem
        }

        if let vendorLabel = preferredVendorVolumeLabel {
            return vendorLabel
        }

        return meaningfulDetectedVolumeName ?? derivedFilenameStem
    }

    private var preferredWindowsVolumeLabel: String {
        let candidates = [
            detectedVolumeName,
            sourceURL.deletingPathExtension().lastPathComponent,
            displayName,
        ]
            .compactMap { $0?.lowercased() }

        for candidate in candidates {
            if candidate.contains("windows 11")
                || candidate.contains("windows11")
                || candidate.contains("win11")
                || candidate.contains("win 11")
                || candidate.contains("w11") {
                return "WIN11"
            }

            if candidate.contains("windows 10")
                || candidate.contains("windows10")
                || candidate.contains("win10")
                || candidate.contains("win 10")
                || candidate.contains("w10") {
                return "WIN10"
            }

            if candidate.contains("windows 8.1")
                || candidate.contains("windows8.1")
                || candidate.contains("win8.1")
                || candidate.contains("win 8.1") {
                return "WIN81"
            }

            if candidate.contains("windows 8")
                || candidate.contains("windows8")
                || candidate.contains("win8")
                || candidate.contains("win 8") {
                return "WIN8"
            }

            if candidate.contains("windows 7")
                || candidate.contains("windows7")
                || candidate.contains("win7")
                || candidate.contains("win 7") {
                return "WIN7"
            }
        }

        return "WINDOWS"
    }

    private var preferredVendorVolumeLabel: String? {
        switch classification?.matchedVendorProfile {
        case .proxmoxVE:
            return "PROXMOX"
        case .trueNAS:
            return "TRUENAS"
        case .openWrt:
            return "OPENWRT"
        case .opnSense:
            return "OPNSENSE"
        case .pfSense:
            return "PFSENSE"
        case .none:
            return nil
        }
    }

    private var meaningfulDetectedVolumeName: String? {
        guard let detectedVolumeName else {
            return nil
        }

        let trimmed = detectedVolumeName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private var derivedFilenameStem: String {
        var stem = sourceURL.lastPathComponent
        let removableExtensions = Set(["iso", "udf", "dmg", "img", "raw", "vhd", "vhdx", "wim", "esd", "gz", "xz", "bz2"])

        while true {
            let extensionValue = URL(fileURLWithPath: stem).pathExtension.lowercased()
            guard !extensionValue.isEmpty, removableExtensions.contains(extensionValue) else {
                break
            }
            stem = URL(fileURLWithPath: stem).deletingPathExtension().lastPathComponent
        }

        let trimmed = stem.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? VolumeLabelFormatter.fallbackLabel : trimmed
    }
}
