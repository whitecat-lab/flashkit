import Foundation
import OSLog

enum MediaWriterError: LocalizedError {
    case blockedPlan(String)

    var errorDescription: String? {
        switch self {
        case let .blockedPlan(reason):
            return reason
        }
    }
}

struct MediaWriterService {
    private let toolchainService = BundledToolchainService()
    private let windowsInstallerService = WindowsInstallerService()
    private let driveImagingService = DriveImagingService()
    private let bootableUtilityService = BootableUtilityService()
    private let strategyResolver = WriteStrategyResolver()
    private let preflightService = WritePreflightService()
    private let logger = Logger(subsystem: "FlashKit", category: "WritePipeline")

    func detectToolStatus() async -> ToolchainStatus {
        await toolchainService.detectToolchain()
    }

    func writeImage(
        sourceImageURL: URL,
        profile: SourceImageProfile,
        plan: WritePlan,
        targetDisk: ExternalDisk,
        volumeLabel: String,
        options: WriteOptions,
        bootAssetsURL: URL?,
        toolchain: ToolchainStatus,
        progress: @escaping @Sendable (WriteSessionUpdate) async -> Void
    ) async throws {
        if plan.isBlocked {
            throw MediaWriterError.blockedPlan(plan.blockingReason ?? "The generated plan is blocked.")
        }

        let resolvedMetadata = try strategyResolver.resolve(
            sourceProfile: profile,
            plan: plan,
            options: options
        )
        let preflight = try await preflightService.validate(
            targetDisk: targetDisk,
            sourceProfile: profile,
            metadata: resolvedMetadata,
            options: options
        )
        let executionMetadata = resolvedMetadata.applying(preflight: preflight)

        logger.info(
            "write run image=\(profile.displayName, privacy: .public) strategy=\(executionMetadata.selectedWriteStrategy.rawValue, privacy: .public) underlying=\(executionMetadata.underlyingWriter.rawValue, privacy: .public) streaming=\(executionMetadata.decompressionStreamingActive, privacy: .public) compression=\(executionMetadata.streamingCompression?.rawValue ?? "none", privacy: .public) vendor=\(executionMetadata.influencingProfile?.rawValue ?? "none", privacy: .public) variant=\(executionMetadata.influencingProfileVariant ?? "none", privacy: .public) overrides=\(executionMetadata.policyExceptionsUsed.map(\.rawValue).joined(separator: ","), privacy: .public)"
        )
        await progress(
            .init(
                phase: "Preparing write",
                message: "Resolved the backend write strategy and revalidated the target disk.",
                fractionCompleted: 0.04,
                details: BackendActivityLogFormatter.writeRunLines(
                    profile: profile,
                    plan: plan,
                    metadata: executionMetadata,
                    preflight: preflight,
                    volumeLabel: volumeLabel
                )
            )
        )

        do {
            switch executionMetadata.underlyingWriter {
            case .windowsInstallerService:
                try await windowsInstallerService.createInstallerMedia(
                    sourceProfile: profile,
                    sourceURL: sourceImageURL,
                    targetDisk: preflight.targetDisk,
                    plan: plan,
                    volumeLabel: volumeLabel,
                    options: options,
                    bootAssetsURL: bootAssetsURL,
                    toolchain: toolchain,
                    executionMetadata: executionMetadata,
                    progress: progress
                )
            case .bootableUtilityService:
                try await bootableUtilityService.createBootableMedia(
                    sourceProfile: profile,
                    sourceURL: sourceImageURL,
                    targetDisk: preflight.targetDisk,
                    plan: plan,
                    volumeLabel: volumeLabel,
                    options: options,
                    toolchain: toolchain,
                    executionMetadata: executionMetadata,
                    progress: progress
                )
            case .rawDeviceWriter:
                try await driveImagingService.restoreImage(
                    sourceProfile: profile,
                    sourceURL: sourceImageURL,
                    plan: plan,
                    targetDisk: preflight.targetDisk,
                    options: options,
                    toolchain: toolchain,
                    executionMetadata: executionMetadata,
                    progress: progress
                )
            }
        } catch {
            logger.error(
                "write failed image=\(profile.displayName, privacy: .public) target=\(preflight.targetDisk.deviceNode, privacy: .public) strategy=\(executionMetadata.selectedWriteStrategy.rawValue, privacy: .public) reason=\(error.localizedDescription, privacy: .public)"
            )
            throw error
        }
    }
}
