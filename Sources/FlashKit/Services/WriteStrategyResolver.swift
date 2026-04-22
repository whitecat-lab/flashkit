import Foundation
import OSLog

struct WriteStrategyResolver {
    private let logger = Logger(subsystem: "FlashKit", category: "WriteStrategy")

    func resolve(
        sourceProfile: SourceImageProfile,
        plan: WritePlan,
        options: WriteOptions
    ) throws -> BackendWriteExecutionMetadata {
        let classification = sourceProfile.classification
        let matchedProfile = classification?.matchedProfile
        let recommendedStrategy = classification?.recommendedWriteStrategy ?? defaultRecommendation(for: sourceProfile, plan: plan)
        let safetyPolicy = classification?.safetyPolicy ?? .safeToProceed
        let compression = RawDiskImageService.compression(for: sourceProfile.sourceURL)
        var policyExceptions: [BackendPolicyException] = []

        if classification?.matchedVendorProfile == .openWrt,
           safetyPolicy == .rejectLikelyWrongImage {
            throw BackendWritePipelineError.unsafeOpenWrtImageType(
                classification?.warnings.first
                    ?? "This looks like a device-specific OpenWrt firmware/sysupgrade artifact rather than a generic USB-bootable disk image."
            )
        }

        if safetyPolicy == .rejectLikelyWrongImage {
            throw BackendWritePipelineError.unsupportedVendorImageVariant(
                matchedProfile?.vendorID ?? .openWrt,
                matchedProfile?.variant
            )
        }

        if (classification?.requiresExpertOverride == true || safetyPolicy == .requireExpertOverride) && !options.expertOverrideEnabled {
            throw BackendWritePipelineError.expertOverrideRequired(
                classification?.warnings.first
                    ?? "The backend could not classify this image confidently enough for a destructive write."
            )
        }

        if options.expertOverrideEnabled,
           classification?.requiresExpertOverride == true || safetyPolicy == .requireExpertOverride {
            policyExceptions.append(.expertOverride)
        }

        let selectedStrategy: BackendWriteStrategy
        let underlyingWriter: BackendUnderlyingWriter

        if let matchedProfile {
            selectedStrategy = .vendorProfileAwareWriter
            underlyingWriter = try underlyingWriterForVendorRecommendation(
                matchedProfile.recommendedWriteStrategy,
                plan: plan,
                vendor: matchedProfile.vendorID
            )
        } else {
            switch defaultUnderlyingWriter(for: plan) {
            case .rawDeviceWriter:
                if plan.payloadMode == .directRaw,
                   (classification?.imageKind == .hybridISO || sourceProfile.isoHybridStyle.isHybrid) {
                    selectedStrategy = .hybridISOWriter
                } else if compression != nil && sourceProfile.format == .dd {
                    selectedStrategy = .streamedDecompressionWriter
                } else {
                    selectedStrategy = .rawDeviceWriter
                }
                underlyingWriter = .rawDeviceWriter
            case let writer:
                selectedStrategy = .vendorProfileAwareWriter
                underlyingWriter = writer
            }
        }

        let metadata = BackendWriteExecutionMetadata(
            selectedWriteStrategy: selectedStrategy,
            underlyingWriter: underlyingWriter,
            decompressionStreamingActive: compression != nil && underlyingWriter == .rawDeviceWriter && sourceProfile.format == .dd,
            streamingCompression: compression,
            influencingProfile: matchedProfile?.vendorID,
            influencingProfileVariant: matchedProfile?.variant,
            recommendedWriteStrategy: recommendedStrategy,
            safetyPolicy: safetyPolicy,
            policyExceptionsUsed: policyExceptions,
            requiresDetachFlow: true,
            helperProtocolVersion: nil,
            helperPID: nil,
            workerPID: nil,
            workerCommand: nil
        )

        logger.info(
            "resolved strategy image=\(sourceProfile.displayName, privacy: .public) selected=\(metadata.selectedWriteStrategy.rawValue, privacy: .public) underlying=\(metadata.underlyingWriter.rawValue, privacy: .public) streaming=\(metadata.decompressionStreamingActive, privacy: .public) compression=\(metadata.streamingCompression?.rawValue ?? "none", privacy: .public) vendor=\(metadata.influencingProfile?.rawValue ?? "none", privacy: .public) variant=\(metadata.influencingProfileVariant ?? "none", privacy: .public) policy=\(metadata.safetyPolicy.rawValue, privacy: .public)"
        )

        return metadata
    }

    private func underlyingWriterForVendorRecommendation(
        _ recommendation: RecommendedWriteStrategy,
        plan: WritePlan,
        vendor: VendorProfileID
    ) throws -> BackendUnderlyingWriter {
        switch recommendation {
        case .rawDiskWrite, .memstickRawWrite, .preserveHybridDirectWrite:
            guard plan.payloadMode == .directRaw else {
                throw BackendWritePipelineError.writeStrategyMismatch(
                    "The detected \(vendor.displayName) image expects a direct raw write backend path, but the current plan resolves to \(plan.payloadMode.rawValue)."
                )
            }
            return .rawDeviceWriter
        case .extractAndRebuild:
            let writer = defaultUnderlyingWriter(for: plan)
            guard writer != .rawDeviceWriter else {
                throw BackendWritePipelineError.writeStrategyMismatch(
                    "The detected \(vendor.displayName) image expects an extract-and-rebuild backend path, but the current plan still resolves to direct raw writing."
                )
            }
            return writer
        case .manualReview:
            throw BackendWritePipelineError.expertOverrideRequired(
                "The detected \(vendor.displayName) image still requires manual expert review before FlashKit can choose a destructive write path."
            )
        case .rejectLikelyWrongImage:
            throw BackendWritePipelineError.unsupportedVendorImageVariant(vendor, nil)
        }
    }

    private func defaultUnderlyingWriter(for plan: WritePlan) -> BackendUnderlyingWriter {
        if plan.mediaMode == .windowsInstaller || plan.payloadMode == .genericOversizedEfi {
            return .windowsInstallerService
        }

        switch plan.payloadMode {
        case .fat32Extract, .freeDOS, .linuxPersistenceCasper, .linuxPersistenceDebian:
            return .bootableUtilityService
        case .directRaw, .fat32SplitWim, .ntfsUefiNtfs, .genericOversizedEfi:
            return plan.mediaMode == .windowsInstaller ? .windowsInstallerService : .rawDeviceWriter
        }
    }

    private func defaultRecommendation(for sourceProfile: SourceImageProfile, plan: WritePlan) -> RecommendedWriteStrategy {
        switch defaultUnderlyingWriter(for: plan) {
        case .rawDeviceWriter:
            if plan.payloadMode == .directRaw,
               (sourceProfile.isoHybridStyle.isHybrid || sourceProfile.classification?.imageKind == .hybridISO) {
                return .preserveHybridDirectWrite
            }

            return .rawDiskWrite
        case .windowsInstallerService, .bootableUtilityService:
            return .extractAndRebuild
        }
    }
}
