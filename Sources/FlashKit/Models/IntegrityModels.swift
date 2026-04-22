import Foundation

enum HashAlgorithm: String, CaseIterable, Sendable {
    case md5
    case sha1
    case sha256

    var displayName: String {
        rawValue.uppercased()
    }
}

struct HashResult: Hashable, Sendable {
    let algorithm: HashAlgorithm
    let hexDigest: String
}

struct BadBlockReport: Sendable, Codable {
    let bytesTested: Int64
    let bytesWritten: Int64
    let badBlockCount: Int
    let suspectedFakeCapacity: Bool
    let notes: [String]
}

enum DownloadCatalogFamily: String, CaseIterable, Identifiable, Codable, Sendable {
    case windows
    case uefiShell

    var id: String { rawValue }

    var label: String {
        switch self {
        case .windows:
            return "Windows"
        case .uefiShell:
            return "UEFI Shell"
        }
    }
}

enum CustomizationPlacement: String, Sendable {
    case autounattendRoot
    case pantherOEM

    var relativePath: String {
        switch self {
        case .autounattendRoot:
            return "autounattend.xml"
        case .pantherOEM:
            return "sources/$OEM$/$$/Panther/unattend.xml"
        }
    }
}

struct CustomizationProfile: Sendable, Equatable {
    var localAccountName: String?
    var preferLocalAccount: Bool
    var bypassSecureBootTPMRAMChecks: Bool
    var bypassOnlineAccountRequirement: Bool
    var disableDataCollection: Bool
    var duplicateHostLocale: Bool
    var disableBitLocker: Bool
    var useMicrosoft2023Bootloaders: Bool

    static let none = CustomizationProfile(
        localAccountName: nil,
        preferLocalAccount: false,
        bypassSecureBootTPMRAMChecks: false,
        bypassOnlineAccountRequirement: false,
        disableDataCollection: false,
        duplicateHostLocale: false,
        disableBitLocker: false,
        useMicrosoft2023Bootloaders: false
    )

    var isEnabled: Bool {
        self != .none
    }

    var requiresWindowsPEPass: Bool {
        bypassSecureBootTPMRAMChecks || useMicrosoft2023Bootloaders
    }

    var preferredPlacement: CustomizationPlacement {
        requiresWindowsPEPass ? .autounattendRoot : .pantherOEM
    }
}

enum DownloadState: String, Sendable {
    case idle
    case catalogReady
    case downloading
    case paused
    case completed
    case failed
}

struct DownloadJob: Identifiable, Sendable {
    let id: UUID
    let title: String
    let sourceURL: URL
    let destinationURL: URL
    var state: DownloadState
    var bytesReceived: Int64
    var expectedBytes: Int64?
    var resumeDataPath: URL?
}

enum SourceMode: String, CaseIterable, Identifiable, Sendable {
    case localFile
    case downloadWindows
    case bundledFreeDOS

    var id: String { rawValue }

    var label: String {
        switch self {
        case .localFile:
            return "Local"
        case .downloadWindows:
            return "Windows"
        case .bundledFreeDOS:
            return "FreeDOS"
        }
    }
}

enum WindowsDownloadArchitecture: String, CaseIterable, Identifiable, Codable, Sendable {
    case x86
    case x64
    case arm64

    var id: String { rawValue }

    var label: String {
        switch self {
        case .x86:
            return "32-bit"
        case .x64:
            return "64-bit"
        case .arm64:
            return "ARM64"
        }
    }
}

struct WindowsDownloadCatalogProduct: Identifiable, Hashable, Codable, Sendable {
    let id: String
    let title: String
    let pagePath: String
    let family: DownloadCatalogFamily
    let releases: [WindowsDownloadRelease]
}

struct WindowsDownloadRelease: Identifiable, Hashable, Codable, Sendable {
    let id: String
    let title: String
    let editions: [WindowsDownloadEdition]
}

struct WindowsDownloadEdition: Identifiable, Hashable, Codable, Sendable {
    let id: String
    let title: String
    let productEditionIDs: [Int]
    let directLinks: [WindowsDownloadLinkOption]?
}

struct WindowsDownloadLanguageOption: Identifiable, Hashable, Codable, Sendable {
    let id: String
    let displayName: String
    let localeName: String
    let skuEntries: [WindowsDownloadSKUEntry]
    let directLinks: [WindowsDownloadLinkOption]?
}

struct WindowsDownloadSKUEntry: Hashable, Codable, Sendable {
    let sessionID: String
    let skuID: String
    let refererPath: String
}

struct WindowsDownloadLinkOption: Identifiable, Hashable, Codable, Sendable {
    let id: String
    let architecture: WindowsDownloadArchitecture
    let displayName: String
    let url: URL
    let filename: String
    let expirationDate: Date?
}

enum DriveCaptureFormat: String, CaseIterable, Sendable {
    case rawImage = "Raw image"
    case vhd = "VHD"
    case vhdx = "VHDX"

    var defaultExtension: String {
        switch self {
        case .rawImage:
            return "img"
        case .vhd:
            return "vhd"
        case .vhdx:
            return "vhdx"
        }
    }
}
