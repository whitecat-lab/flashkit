import Foundation

enum BackendWriteStrategy: String, Sendable {
    case rawDeviceWriter = "raw-device-writer"
    case streamedDecompressionWriter = "streamed-decompression-writer"
    case hybridISOWriter = "hybrid-iso-writer"
    case vendorProfileAwareWriter = "vendor-profile-aware-writer"
}

enum BackendUnderlyingWriter: String, Sendable {
    case rawDeviceWriter = "raw-device-writer"
    case windowsInstallerService = "windows-installer-service"
    case bootableUtilityService = "bootable-utility-service"
}

enum BackendPolicyException: String, Hashable, Sendable {
    case expertOverride = "expert-override"
    case nonRemovableTarget = "non-removable-target"
}

struct BackendPreflightResult: Sendable {
    let targetDisk: ExternalDisk
    let requiresDetachFlow: Bool
    let policyExceptionsUsed: [BackendPolicyException]
}

struct BackendWriteExecutionMetadata: Sendable {
    let selectedWriteStrategy: BackendWriteStrategy
    let underlyingWriter: BackendUnderlyingWriter
    let decompressionStreamingActive: Bool
    let streamingCompression: RawDiskCompression?
    let influencingProfile: VendorProfileID?
    let influencingProfileVariant: String?
    let recommendedWriteStrategy: RecommendedWriteStrategy
    let safetyPolicy: ImageSafetyPolicy
    let policyExceptionsUsed: [BackendPolicyException]
    let requiresDetachFlow: Bool
    let helperProtocolVersion: Int?
    let helperPID: Int32?
    let workerPID: Int32?
    let workerCommand: [String]?

    func applying(preflight: BackendPreflightResult) -> BackendWriteExecutionMetadata {
        BackendWriteExecutionMetadata(
            selectedWriteStrategy: selectedWriteStrategy,
            underlyingWriter: underlyingWriter,
            decompressionStreamingActive: decompressionStreamingActive,
            streamingCompression: streamingCompression,
            influencingProfile: influencingProfile,
            influencingProfileVariant: influencingProfileVariant,
            recommendedWriteStrategy: recommendedWriteStrategy,
            safetyPolicy: safetyPolicy,
            policyExceptionsUsed: Array(Set(policyExceptionsUsed).union(preflight.policyExceptionsUsed)).sorted { $0.rawValue < $1.rawValue },
            requiresDetachFlow: preflight.requiresDetachFlow,
            helperProtocolVersion: helperProtocolVersion,
            helperPID: helperPID,
            workerPID: workerPID,
            workerCommand: workerCommand
        )
    }

    func applying(workerTelemetry: BackendWorkerRuntimeTelemetry) -> BackendWriteExecutionMetadata {
        BackendWriteExecutionMetadata(
            selectedWriteStrategy: selectedWriteStrategy,
            underlyingWriter: underlyingWriter,
            decompressionStreamingActive: decompressionStreamingActive,
            streamingCompression: streamingCompression,
            influencingProfile: influencingProfile,
            influencingProfileVariant: influencingProfileVariant,
            recommendedWriteStrategy: recommendedWriteStrategy,
            safetyPolicy: safetyPolicy,
            policyExceptionsUsed: policyExceptionsUsed,
            requiresDetachFlow: requiresDetachFlow,
            helperProtocolVersion: workerTelemetry.helperProtocolVersion,
            helperPID: workerTelemetry.helperPID,
            workerPID: workerTelemetry.workerPID,
            workerCommand: workerTelemetry.workerCommand
        )
    }
}

enum BackendWritePipelineError: LocalizedError {
    case unsupportedVendorImageVariant(VendorProfileID, String?)
    case unsafeOpenWrtImageType(String)
    case targetRevalidationFailure(String)
    case ambiguousTargetDevice(String)
    case decompressionStreamFailure(String)
    case writeStrategyMismatch(String)
    case expertOverrideRequired(String)
    case unsafeImageProfileCombination(String)

    var errorDescription: String? {
        switch self {
        case let .unsupportedVendorImageVariant(vendor, variant):
            if let variant, !variant.isEmpty {
                return "\(vendor.displayName) \(variant) images are not supported by the current backend write path."
            }
            return "\(vendor.displayName) media was detected, but this image variant is not supported by the current backend write path."
        case let .unsafeOpenWrtImageType(message):
            return message
        case let .targetRevalidationFailure(message):
            return message
        case let .ambiguousTargetDevice(message):
            return message
        case let .decompressionStreamFailure(message):
            return message
        case let .writeStrategyMismatch(message):
            return message
        case let .expertOverrideRequired(message):
            return message
        case let .unsafeImageProfileCombination(message):
            return message
        }
    }
}
