import Foundation

enum HelperTool: String, CaseIterable, Hashable, Sendable {
    case diskutil
    case hdiutil
    case dd
    case newfsMsdos = "newfs_msdos"
    case newfsUdf = "newfs_udf"
    case wimlibImagex = "wimlib-imagex"
    case uefiNTFSImage = "uefi-ntfs.img"
    case qemuImg = "qemu-img"
    case mkntfs
    case ntfsPopulateHelper = "ntfs-populate-helper"
    case ntfsfix
    case mke2fs
    case debugfs
    case freedosBootHelper = "freedos-boot-helper"
    case xz
    case shasum

    var isSystemTool: Bool {
        switch self {
        case .diskutil, .hdiutil, .dd, .newfsMsdos, .newfsUdf, .shasum:
            return true
        case .wimlibImagex, .uefiNTFSImage, .qemuImg, .mkntfs, .ntfsPopulateHelper, .ntfsfix, .mke2fs, .debugfs, .freedosBootHelper, .xz:
            return false
        }
    }

    var isBundledRuntimeRequirement: Bool {
        !isSystemTool
    }

    var validationArguments: [String]? {
        switch self {
        case .wimlibImagex, .qemuImg, .mkntfs, .ntfsPopulateHelper, .ntfsfix, .freedosBootHelper, .xz:
            return ["--version"]
        case .mke2fs, .debugfs:
            return ["-V"]
        case .uefiNTFSImage:
            return []
        case .diskutil, .hdiutil, .dd, .newfsMsdos, .newfsUdf, .shasum:
            return nil
        }
    }

    var userFacingName: String {
        switch self {
        case .diskutil, .hdiutil, .dd, .newfsMsdos, .newfsUdf, .shasum:
            return "Core macOS disk tools"
        case .wimlibImagex:
            return "Windows patching helper"
        case .uefiNTFSImage:
            return "Oversized Windows ISO boot asset"
        case .qemuImg:
            return "VHD/VHDX restore helper"
        case .mkntfs:
            return "NTFS formatting helper"
        case .ntfsPopulateHelper:
            return "NTFS Windows media helper"
        case .ntfsfix:
            return "NTFS finalization helper"
        case .mke2fs:
            return "ext formatting helper"
        case .debugfs:
            return "ext persistence helper"
        case .freedosBootHelper:
            return "FreeDOS boot helper"
        case .xz:
            return "XZ decompression helper"
        }
    }

    var affectedFeatures: [ToolchainFeature] {
        switch self {
        case .wimlibImagex:
            return [.windowsPatching]
        case .uefiNTFSImage:
            return [.oversizedWindowsISOs]
        case .qemuImg:
            return [.vhdVhdxRestore]
        case .mkntfs, .ntfsPopulateHelper, .ntfsfix:
            return [.ntfsFormatting]
        case .mke2fs, .debugfs:
            return [.extFormatting]
        case .freedosBootHelper:
            return [.freeDOSMedia]
        case .xz:
            return []
        case .diskutil, .hdiutil, .dd, .newfsMsdos, .newfsUdf, .shasum:
            return [.coreDiskTools]
        }
    }
}

enum ToolSource: String, Hashable, Sendable {
    case system
    case bundled
    case missing
}

enum ToolValidationState: String, Hashable, Sendable {
    case ready
    case missing
    case broken
}

enum ToolchainFeature: String, CaseIterable, Hashable, Sendable {
    case windowsPatching
    case oversizedWindowsISOs
    case vhdVhdxRestore
    case ntfsFormatting
    case extFormatting
    case freeDOSMedia
    case coreDiskTools

    var label: String {
        switch self {
        case .windowsPatching:
            return "Windows patching"
        case .oversizedWindowsISOs:
            return "Oversized Windows ISOs"
        case .vhdVhdxRestore:
            return "VHD/VHDX restore"
        case .ntfsFormatting:
            return "NTFS Windows media"
        case .extFormatting:
            return "ext formatting"
        case .freeDOSMedia:
            return "FreeDOS media"
        case .coreDiskTools:
            return "Core disk tools"
        }
    }
}

enum ToolchainReadiness: String, Sendable {
    case ready
    case degraded
}

struct ToolAvailability: Hashable, Sendable {
    let tool: HelperTool
    let path: String?
    let source: ToolSource
    let validationState: ToolValidationState
    let validationMessage: String?

    var isAvailable: Bool {
        validationState == .ready && path != nil
    }

    var issueDescription: String? {
        switch validationState {
        case .ready:
            return nil
        case .missing:
            if tool.isSystemTool {
                return "\(tool.userFacingName) could not be found on this Mac."
            }
            return "\(tool.userFacingName) is missing from the app bundle."
        case .broken:
            return validationMessage ?? "\(tool.userFacingName) failed validation."
        }
    }
}

struct ToolchainStatus: Sendable {
    let tools: [HelperTool: ToolAvailability]

    static let empty = ToolchainStatus(tools: [:])

    func availability(for tool: HelperTool) -> ToolAvailability {
        tools[tool] ?? ToolAvailability(tool: tool, path: nil, source: .missing, validationState: .missing, validationMessage: nil)
    }

    func path(for tool: HelperTool) -> String? {
        let availability = availability(for: tool)
        return availability.isAvailable ? availability.path : nil
    }

    var hasWimlibImagex: Bool {
        availability(for: .wimlibImagex).isAvailable
    }

    var hasUEFINTFSImage: Bool {
        availability(for: .uefiNTFSImage).isAvailable
    }

    var hasNTFSFormatter: Bool {
        availability(for: .mkntfs).isAvailable
    }

    var hasNTFSPopulateHelper: Bool {
        availability(for: .ntfsPopulateHelper).isAvailable
    }

    var hasExtFormatter: Bool {
        availability(for: .mke2fs).isAvailable
    }

    var unavailableFeatures: [ToolchainFeature] {
        ToolchainFeature.allCases.filter { feature in
            tools.values.contains { availability in
                availability.validationState != .ready && availability.tool.affectedFeatures.contains(feature)
            }
        }
    }

    var readiness: ToolchainReadiness {
        unavailableFeatures.isEmpty ? .ready : .degraded
    }

    var summaryLine: String {
        if unavailableFeatures.isEmpty {
            return "Self-contained bundle ready"
        }

        let labels = unavailableFeatures.map(\.label).joined(separator: ", ")
        return "Bundle incomplete: \(labels)"
    }

    var detailedWarning: String? {
        let unavailableFeatureList = unavailableFeatures
        guard !unavailableFeatureList.isEmpty else {
            return nil
        }

        let labels = unavailableFeatureList.map(\.label).joined(separator: ", ")
        let details = unavailableFeatureList.compactMap(featureDetail(for:))

        if details.isEmpty {
            return "Some features are unavailable on this Mac: \(labels)."
        }

        return "Some features are unavailable on this Mac: \(labels). \(details.joined(separator: " "))"
    }

    func blockingReason(for requirements: [HelperRequirement]) -> String? {
        for requirement in requirements {
            let availability = availability(for: requirement.tool)
            guard availability.validationState != .ready else {
                continue
            }

            if let issueDescription = availability.issueDescription {
                return "\(requirement.reason). \(issueDescription)"
            }

            return requirement.reason
        }

        return nil
    }

    private func featureDetail(for feature: ToolchainFeature) -> String? {
        switch feature {
        case .ntfsFormatting:
            return "NTFS Windows media is not fully bundled in this build."
        case .windowsPatching:
            return "Windows patching is unavailable in this bundle."
        case .oversizedWindowsISOs:
            return "Oversized Windows ISO boot support is unavailable."
        case .vhdVhdxRestore:
            return "VHD/VHDX restore is unavailable in this bundle."
        case .extFormatting:
            return "ext formatting is unavailable in this bundle."
        case .coreDiskTools:
            return "Required macOS disk tools are unavailable on this Mac."
        case .freeDOSMedia:
            return "FreeDOS boot media support is unavailable in this bundle."
        }
    }
}
