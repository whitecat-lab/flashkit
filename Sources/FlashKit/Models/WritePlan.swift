import Foundation

enum FilesystemType: String, CaseIterable, Sendable {
    case fat
    case fat32
    case ntfs
    case exfat
    case udf
    case ext2
    case ext3
    case ext4
}

enum TargetSystem: String, CaseIterable, Sendable {
    case bios = "BIOS"
    case uefi = "UEFI"
    case dual = "BIOS + UEFI"
}

enum PartitionScheme: String, CaseIterable, Sendable {
    case mbr = "MBR"
    case gpt = "GPT"
    case superFloppy = "Super Floppy"
}

enum WindowsInstallerPayloadMode: String, Sendable {
    case directRaw = "Direct raw image"
    case fat32SplitWim = "FAT32 + split WIM"
    case fat32Extract = "FAT32 extract"
    case ntfsUefiNtfs = "NTFS + UEFI:NTFS"
    case genericOversizedEfi = "Generic oversized EFI"
    case freeDOS = "FreeDOS"
    case linuxPersistenceCasper = "Linux persistence (casper)"
    case linuxPersistenceDebian = "Linux persistence (debian)"

    var badgeLabel: String {
        switch self {
        case .directRaw:
            return "RAW"
        case .fat32SplitWim:
            return "FAT32"
        case .fat32Extract:
            return "EXTRACT"
        case .ntfsUefiNtfs:
            return "NTFS"
        case .genericOversizedEfi:
            return "EFI-LARGE"
        case .freeDOS:
            return "DOS"
        case .linuxPersistenceCasper, .linuxPersistenceDebian:
            return "PERSIST"
        }
    }
}

enum VerificationMode: String, Sendable {
    case none
    case windowsInstallerManifest = "Windows manifest"
    case rawByteCompare = "Raw byte compare"
    case vhdxRoundTrip = "VHD/VHDX round-trip"
    case bootArtifacts = "Boot artifacts"
}

enum PostWriteFixupStep: String, Hashable, Sendable {
    case windows7EFIFallback
    case biosWinPEFixup
    case preservePantherUnattend
    case injectAutounattend
    case injectPantherUnattend
    case repairEFISystemPartition
    case ntfsFinalize
    case normalizeSetupBootArtifacts
    case injectWindows11BypassArtifacts
    case useMicrosoft2023Bootloaders
    case freeDOSBootSector
    case linuxPersistenceConfig

    var description: String {
        switch self {
        case .windows7EFIFallback:
            return "Extract bootmgfw.efi from boot.wim as EFI/BOOT/BOOTX64.EFI"
        case .biosWinPEFixup:
            return "Apply BIOS-targeted WinPE setup loader fixups"
        case .preservePantherUnattend:
            return "Preserve the existing Panther unattended configuration"
        case .injectAutounattend:
            return "Inject Autounattend.xml at the media root"
        case .injectPantherUnattend:
            return "Inject unattended configuration through sources/$OEM$/$$/Panther"
        case .repairEFISystemPartition:
            return "Rebuild missing EFI fallback boot files for extracted firmware-facing media"
        case .ntfsFinalize:
            return "Run the NTFS finalization pass before success is reported"
        case .normalizeSetupBootArtifacts:
            return "Normalize Windows setup boot artifacts for BIOS and UEFI compatibility"
        case .injectWindows11BypassArtifacts:
            return "Inject Windows setup bypass placeholder artifacts"
        case .useMicrosoft2023Bootloaders:
            return "Replace EFI bootloaders with Microsoft 2023-signed copies when available"
        case .freeDOSBootSector:
            return "Write a FreeDOS-compatible FAT boot sector"
        case .linuxPersistenceConfig:
            return "Patch Linux boot config and create a persistence partition"
        }
    }
}

struct HelperRequirement: Hashable, Sendable {
    let tool: HelperTool
    let reason: String
}

struct PartitionLayout: Hashable, Sendable {
    let name: String
    let filesystem: FilesystemType
    let sizeMiB: Int?
    let description: String
}

struct WritePlan: Sendable {
    let mediaMode: MediaMode
    let payloadMode: WindowsInstallerPayloadMode
    let partitionScheme: PartitionScheme
    let targetSystem: TargetSystem
    let primaryFilesystem: FilesystemType?
    let partitionLayouts: [PartitionLayout]
    let helperRequirements: [HelperRequirement]
    let postWriteFixups: [PostWriteFixupStep]
    let verificationMode: VerificationMode
    let verificationSteps: [String]
    let warnings: [String]
    let summary: String
    let isBlocked: Bool
    let blockingReason: String?

    var usesUEFINTFSPath: Bool {
        payloadMode == .ntfsUefiNtfs || payloadMode == .genericOversizedEfi
    }

    var badgeLabels: [String] {
        var labels = [mediaMode.rawValue, targetSystem.rawValue, partitionScheme.rawValue]
        if payloadMode != .directRaw {
            labels.append(payloadMode.badgeLabel)
        }
        if let primaryFilesystem {
            labels.append(primaryFilesystem.rawValue.uppercased())
        }
        if usesUEFINTFSPath {
            labels.append("UEFI:NTFS")
        }
        return labels
    }
}
