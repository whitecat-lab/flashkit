import Foundation

enum MediaValidationDepth: String, Sendable {
    case quick
    case full
}

enum MediaValidationCheckStatus: String, Sendable {
    case passed
    case warning
    case failed
    case skipped
}

struct MediaValidationCheck: Sendable {
    let identifier: String
    let title: String
    let status: MediaValidationCheckStatus
    let detail: String
}

struct ValidationPartitionSnapshot: Sendable {
    let identifier: String
    let deviceNode: String
    let mountPoint: URL?
    let filesystemDescription: String
    let contentDescription: String
}

struct MediaTargetSnapshot: Sendable {
    let wholeDiskIdentifier: String
    let deviceNode: String
    let partitionTableReadable: Bool
    let partitions: [ValidationPartitionSnapshot]

    var mountedRoots: [URL] {
        partitions.compactMap(\.mountPoint)
    }
}

struct MediaValidationResult: Sendable {
    let passed: Bool
    let confidence: Double
    let depth: MediaValidationDepth
    let checksPerformed: [MediaValidationCheck]
    let warnings: [String]
    let profileNotes: [String]
    let structurallyPlausibleButNotGuaranteedBootable: Bool
    let matchedProfile: VendorProfileID?
    let profileVariant: String?
    let failureReason: String?
}

struct MediaValidationContext: Sendable {
    let sourceProfile: SourceImageProfile
    let targetDisk: ExternalDisk
    let plan: WritePlan
    let executionMetadata: BackendWriteExecutionMetadata?
    let destinationRoot: URL?
    let ntfsDestinationPartition: DiskPartition?
    let customization: CustomizationProfile
    let toolchain: ToolchainStatus
    let snapshot: MediaTargetSnapshot
}

enum MediaValidationServiceError: LocalizedError {
    case failed(MediaValidationResult)

    var errorDescription: String? {
        switch self {
        case let .failed(result):
            return result.failureReason ?? "Post-write validation failed."
        }
    }
}
