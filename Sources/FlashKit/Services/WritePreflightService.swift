import Foundation
import OSLog

struct WritePreflightService {
    private let logger = Logger(subsystem: "FlashKit", category: "WritePreflight")
    private let listExternalDisks: @Sendable () async throws -> [ExternalDisk]
    private let diskInfo: @Sendable (String) async throws -> [String: Any]
    private let mountedPartitions: @Sendable (String) async throws -> [DiskPartition]

    init(
        listExternalDisks: @escaping @Sendable () async throws -> [ExternalDisk] = { try await DiskService().listExternalDisks() },
        diskInfo: @escaping @Sendable (String) async throws -> [String: Any] = { try await DiskService().diskInfo(for: $0) },
        mountedPartitions: @escaping @Sendable (String) async throws -> [DiskPartition] = { try await DiskService().mountedPartitions(forWholeDisk: $0) }
    ) {
        self.listExternalDisks = listExternalDisks
        self.diskInfo = diskInfo
        self.mountedPartitions = mountedPartitions
    }

    func validate(
        targetDisk: ExternalDisk,
        sourceProfile: SourceImageProfile,
        metadata: BackendWriteExecutionMetadata,
        options: WriteOptions
    ) async throws -> BackendPreflightResult {
        let diskInfo = try await diskInfo(targetDisk.identifier)
        guard diskInfo["WholeDisk"] as? Bool ?? false else {
            throw BackendWritePipelineError.targetRevalidationFailure(
                "The selected target is no longer available as a whole removable disk."
            )
        }

        let currentDeviceNode = diskInfo["DeviceNode"] as? String ?? targetDisk.deviceNode
        guard currentDeviceNode == targetDisk.deviceNode else {
            throw BackendWritePipelineError.targetRevalidationFailure(
                "The selected target changed from \(targetDisk.deviceNode) to \(currentDeviceNode) before the write began."
            )
        }

        let currentSize = PropertyListLoader.integer64(diskInfo["TotalSize"]) ?? PropertyListLoader.integer64(diskInfo["Size"]) ?? targetDisk.size
        guard currentSize == targetDisk.size else {
            throw BackendWritePipelineError.targetRevalidationFailure(
                "The selected target changed size before the write began."
            )
        }

        guard diskInfo["WritableMedia"] as? Bool ?? targetDisk.writable else {
            throw BackendWritePipelineError.targetRevalidationFailure(
                "The selected target is no longer writable."
            )
        }

        let externalDisks = try await listExternalDisks()
        let matchingExternalDisks = externalDisks.filter {
            $0.identifier == targetDisk.identifier || $0.deviceNode == targetDisk.deviceNode
        }

        guard matchingExternalDisks.count <= 1 else {
            throw BackendWritePipelineError.ambiguousTargetDevice(
                "FlashKit found multiple removable targets that match the selected device. Re-select the USB drive before writing."
            )
        }

        let isInternal = diskInfo["Internal"] as? Bool ?? false
        let isRemovable = diskInfo["Removable"] as? Bool ?? (diskInfo["RemovableMedia"] as? Bool ?? targetDisk.removable)
        var policyExceptions = metadata.policyExceptionsUsed

        if isInternal || !isRemovable || matchingExternalDisks.isEmpty {
            if options.expertOverrideEnabled {
                policyExceptions.append(.nonRemovableTarget)
            } else {
                throw BackendWritePipelineError.targetRevalidationFailure(
                    "The selected target no longer looks like the same removable USB device. FlashKit will not write to an internal or ambiguous disk without an expert override."
                )
            }
        }

        if let classification = sourceProfile.classification,
           classification.safetyPolicy == .requireExpertOverride,
           !options.expertOverrideEnabled {
            throw BackendWritePipelineError.expertOverrideRequired(
                classification.warnings.first
                    ?? "The detected image still requires an expert override before a destructive write can continue."
            )
        }

        let requiresDetachFlow = ((try? await mountedPartitions(targetDisk.identifier).isEmpty) == false)
        let refreshedDisk = matchingExternalDisks.first ?? targetDisk

        logger.info(
            "preflight target=\(refreshedDisk.deviceNode, privacy: .public) strategy=\(metadata.selectedWriteStrategy.rawValue, privacy: .public) vendor=\(metadata.influencingProfile?.rawValue ?? "none", privacy: .public) detachable=\(requiresDetachFlow, privacy: .public) exceptions=\(policyExceptions.map(\.rawValue).joined(separator: ","), privacy: .public)"
        )

        return BackendPreflightResult(
            targetDisk: refreshedDisk,
            requiresDetachFlow: requiresDetachFlow,
            policyExceptionsUsed: policyExceptions
        )
    }
}
