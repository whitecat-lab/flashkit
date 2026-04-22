import Foundation

enum BackendActivityLogFormatter {
    static func classificationLines(for profile: SourceImageProfile) -> [String] {
        var lines: [String] = []

        let classification = profile.classification
        lines.append(
            "[CLASSIFY] image=\(profile.displayName) format=\(profile.format.rawValue) kind=\(classification?.imageKind.rawValue ?? "unclassified") efi=\(profile.hasEFI) bios=\(profile.hasBIOS)"
        )

        if let classification {
            lines.append(
                "[CLASSIFY] vendor=\(classification.matchedVendorProfile?.rawValue ?? "none") variant=\(classification.matchedProfile?.variant ?? "none") confidence=\(score(classification.confidence)) safety=\(classification.safetyPolicy.rawValue) strategy=\(classification.recommendedWriteStrategy.rawValue)"
            )

            if !classification.evidence.isEmpty {
                lines.append("[CLASSIFY] evidence=\(classification.evidence.joined(separator: " | "))")
            }

            if !classification.warnings.isEmpty {
                lines.append("[CLASSIFY] warnings=\(classification.warnings.joined(separator: " | "))")
            }
        } else if let warning = profile.warningSummary {
            lines.append("[CLASSIFY] notes=\(warning)")
        }

        return lines
    }

    static func planLines(for profile: SourceImageProfile, plan: WritePlan, volumeLabel: String) -> [String] {
        var lines = [
            "[PLAN] mode=\(plan.mediaMode.rawValue) payload=\(plan.payloadMode.rawValue) target=\(plan.targetSystem.rawValue) scheme=\(plan.partitionScheme.rawValue) filesystem=\(plan.primaryFilesystem?.rawValue.uppercased() ?? "NONE")",
            "[PLAN] label=\(VolumeLabelFormatter.sanitizedFATLabel(volumeLabel)) partitions=\(partitionSummary(for: plan, volumeLabel: volumeLabel))",
        ]

        if let blockingReason = plan.blockingReason {
            lines.append("[PLAN] blocked=\(blockingReason)")
        } else {
            lines.append("[PLAN] summary=\(plan.summary)")
        }

        if !plan.warnings.isEmpty {
            lines.append("[PLAN] warnings=\(plan.warnings.joined(separator: " | "))")
        }

        if let appliance = profile.applianceProfile {
            lines.append("[PLAN] appliance=\(appliance.displayName)")
        }

        return lines
    }

    static func writeRunLines(
        profile: SourceImageProfile,
        plan: WritePlan,
        metadata: BackendWriteExecutionMetadata,
        preflight: BackendPreflightResult,
        volumeLabel: String
    ) -> [String] {
        var lines = [
            "[WRITE] image=\(profile.displayName) strategy=\(metadata.selectedWriteStrategy.rawValue) underlying=\(metadata.underlyingWriter.rawValue) recommended=\(metadata.recommendedWriteStrategy.rawValue)",
            "[WRITE] profile=\(metadata.influencingProfile?.rawValue ?? "none") variant=\(metadata.influencingProfileVariant ?? "none") policy=\(metadata.safetyPolicy.rawValue) streaming=\(metadata.decompressionStreamingActive) compression=\(metadata.streamingCompression?.rawValue ?? "none")",
            "[WRITE] target=\(preflight.targetDisk.deviceNode) name=\(preflight.targetDisk.displayName) size=\(preflight.targetDisk.sizeDescription) bus=\(preflight.targetDisk.busProtocol ?? "unknown") removable=\(preflight.targetDisk.removable) ejectable=\(preflight.targetDisk.ejectable) writable=\(preflight.targetDisk.writable)",
            "[WRITE] preflight=passed detach-flow=\(metadata.requiresDetachFlow) exceptions=\(policySummary(metadata.policyExceptionsUsed))",
            "[WRITE] partitions=\(partitionSummary(for: plan, volumeLabel: volumeLabel))",
        ]

        if metadata.safetyPolicy == .requireExpertOverride || !metadata.policyExceptionsUsed.isEmpty {
            lines.append("[WRITE] override-required=\(metadata.safetyPolicy == .requireExpertOverride) override-used=\(metadata.policyExceptionsUsed.contains(.expertOverride))")
        }

        if let helperProtocolVersion = metadata.helperProtocolVersion {
            lines.append(
                "[WRITE] helper-protocol=\(helperProtocolVersion) helper-pid=\(metadata.helperPID.map(String.init) ?? "n/a") child-pid=\(metadata.workerPID.map(String.init) ?? "n/a") command=\(metadata.workerCommand?.joined(separator: " ") ?? "n/a")"
            )
        }

        return lines
    }

    static func workerLines(_ telemetry: BackendWorkerRuntimeTelemetry, mode: String) -> [String] {
        var lines = [
            "[WORKER] mode=\(mode) helper-protocol=\(telemetry.helperProtocolVersion) helper-pid=\(telemetry.helperPID == 0 ? "n/a" : String(telemetry.helperPID)) child-pid=\(telemetry.workerPID.map(String.init) ?? "n/a")",
        ]

        if let workerCommand = telemetry.workerCommand, !workerCommand.isEmpty {
            lines.append("[WORKER] command=\(workerCommand.joined(separator: " "))")
        }

        return lines
    }

    static func progressLines(
        phase: String,
        completedBytes: Int64,
        totalBytes: Int64,
        rateBytesPerSecond: Double?
    ) -> [String] {
        let transferred = ByteCountFormatter.string(fromByteCount: completedBytes, countStyle: .file)
        let total = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
        let percent = totalBytes > 0 ? Int((Double(completedBytes) / Double(totalBytes)) * 100) : 0
        let rateDescription = rateBytesPerSecond.map {
            "\(ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file))/s"
        } ?? "n/a"

        return [
            "[PROGRESS] phase=\(phase) bytes=\(transferred)/\(total) percent=\(percent)% rate=\(rateDescription)",
        ]
    }

    static func partitionWriteLines(for plan: WritePlan, volumeLabel: String) -> [String] {
        [
            "[WRITE] partition-layout=\(partitionSummary(for: plan, volumeLabel: volumeLabel))",
        ]
    }

    static func validationLines(_ result: MediaValidationResult) -> [String] {
        var lines = [
            "[VALIDATE] passed=\(result.passed) confidence=\(score(result.confidence)) depth=\(result.depth.rawValue) plausible-only=\(result.structurallyPlausibleButNotGuaranteedBootable) vendor=\(result.matchedProfile?.rawValue ?? "none") variant=\(result.profileVariant ?? "none")",
            "[VALIDATE] checks=\(result.checksPerformed.map { "\($0.identifier):\($0.status.rawValue)" }.joined(separator: ", "))",
        ]

        if let failureReason = result.failureReason {
            lines.append("[VALIDATE] failure=\(failureReason)")
        }

        if !result.warnings.isEmpty {
            lines.append("[VALIDATE] warnings=\(result.warnings.joined(separator: " | "))")
        }

        if !result.profileNotes.isEmpty {
            lines.append("[VALIDATE] notes=\(result.profileNotes.joined(separator: " | "))")
        }

        return lines
    }

    private static func partitionSummary(for plan: WritePlan, volumeLabel: String) -> String {
        let layouts = PartitioningService.resolvedPartitionLayouts(for: plan, volumeLabel: volumeLabel)
        guard !layouts.isEmpty else {
            return "preserve-source-layout"
        }

        return layouts.map { layout in
            let size = layout.sizeMiB.map { "\($0)MiB" } ?? "rest"
            return "\(layout.name):\(layout.filesystem.rawValue.uppercased()):\(size)"
        }
            .joined(separator: " | ")
    }

    private static func policySummary(_ exceptions: [BackendPolicyException]) -> String {
        exceptions.isEmpty ? "none" : exceptions.map(\.rawValue).joined(separator: ",")
    }

    private static func score(_ value: Double) -> String {
        String(format: "%.2f", value)
    }
}
