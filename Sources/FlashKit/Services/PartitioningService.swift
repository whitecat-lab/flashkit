import Foundation

enum PartitioningServiceError: LocalizedError {
    case unexpectedPartitionLayout

    var errorDescription: String? {
        switch self {
        case .unexpectedPartitionLayout:
            return "The target disk was partitioned, but the expected partition layout was not discovered."
        }
    }
}

struct PreparedInstallerTarget: Sendable {
    let primaryPartition: DiskPartition
    let helperPartition: DiskPartition?
    let auxiliaryPartitions: [DiskPartition]
}

struct PartitioningService {
    private let privileged = PrivilegedCommandService()
    private let diskService = DiskService()

    func prepareInstallerTarget(
        plan: WritePlan,
        targetDisk: ExternalDisk,
        volumeLabel: String
    ) async throws -> PreparedInstallerTarget {
        let scheme = plan.partitionScheme == .gpt ? "GPTFormat" : "MBRFormat"
        let layouts = Self.resolvedPartitionLayouts(for: plan, volumeLabel: volumeLabel)

        var arguments = [
            "partitionDisk",
            targetDisk.deviceNode,
            scheme,
        ]

        for (index, layout) in layouts.enumerated() {
            arguments.append(diskutilType(for: layout.filesystem))
            arguments.append(VolumeLabelFormatter.sanitizedVolumeName(layout.name, filesystem: layout.filesystem))
            if let sizeMiB = layout.sizeMiB {
                arguments.append("\(sizeMiB)M")
            } else if index == layouts.count - 1 {
                arguments.append("R")
            } else {
                arguments.append("0M")
            }
        }

        try await privileged.run("/usr/sbin/diskutil", arguments: arguments)

        let partitions = try await diskService.mountedPartitions(forWholeDisk: targetDisk.identifier)
        guard partitions.count >= layouts.count else {
            throw PartitioningServiceError.unexpectedPartitionLayout
        }

        let sorted = partitions.sorted { $0.identifier < $1.identifier }
        if plan.usesUEFINTFSPath {
            return PreparedInstallerTarget(
                primaryPartition: sorted[1],
                helperPartition: sorted.first,
                auxiliaryPartitions: Array(sorted.dropFirst(2))
            )
        }

        return PreparedInstallerTarget(
            primaryPartition: sorted[0],
            helperPartition: nil,
            auxiliaryPartitions: Array(sorted.dropFirst())
        )
    }

    static func resolvedPartitionLayouts(for plan: WritePlan, volumeLabel: String) -> [PartitionLayout] {
        let sanitizedLabel = VolumeLabelFormatter.sanitizedFATLabel(volumeLabel)

        if plan.partitionLayouts.isEmpty {
            return [PartitionLayout(name: sanitizedLabel, filesystem: .fat32, sizeMiB: nil, description: "Bootable payload")]
        }

        let payloadIndex = plan.usesUEFINTFSPath ? 1 : 0
        return plan.partitionLayouts.enumerated().map { index, layout in
            guard index == payloadIndex else {
                return layout
            }

            return PartitionLayout(
                name: sanitizedLabel,
                filesystem: layout.filesystem,
                sizeMiB: layout.sizeMiB,
                description: layout.description
            )
        }
    }

    private func diskutilType(for filesystem: FilesystemType) -> String {
        switch filesystem {
        case .fat, .fat32:
            return "FAT32"
        case .exfat:
            return "ExFAT"
        case .udf:
            return "Free Space"
        case .ntfs:
            return "Free Space"
        case .ext2, .ext3, .ext4:
            return "Free Space"
        }
    }
}
