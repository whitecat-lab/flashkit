import Foundation

enum FilesystemServiceError: LocalizedError {
    case unsupportedFilesystem(FilesystemType)
    case missingHelper(HelperTool)

    var errorDescription: String? {
        switch self {
        case let .unsupportedFilesystem(filesystem):
            return "Formatting \(filesystem.rawValue) is not supported yet."
        case let .missingHelper(tool):
            return "The required helper \(tool.rawValue) is not available."
        }
    }
}

struct FilesystemService {
    private let runner = ProcessRunner()
    private let privileged = PrivilegedCommandService()

    func formatPartition(
        partition: DiskPartition,
        filesystem: FilesystemType,
        volumeName: String,
        toolchain: ToolchainStatus
    ) async throws {
        switch filesystem {
        case .fat, .fat32:
            try await privileged.run(
                "/usr/sbin/diskutil",
                arguments: ["eraseVolume", "FAT32", VolumeLabelFormatter.sanitizedFATLabel(volumeName), partition.deviceNode]
            )
        case .exfat:
            try await privileged.run(
                "/usr/sbin/diskutil",
                arguments: ["eraseVolume", "ExFAT", volumeName, partition.deviceNode]
            )
        case .udf:
            guard let formatter = toolchain.path(for: .newfsUdf) else {
                throw FilesystemServiceError.missingHelper(.newfsUdf)
            }
            try await privileged.run(
                formatter,
                arguments: ["-v", volumeName, partition.deviceNode]
            )
            _ = try? await runner.run("/usr/sbin/diskutil", arguments: ["mount", partition.deviceNode])
        case .ntfs:
            guard let formatter = toolchain.path(for: .mkntfs) else {
                throw FilesystemServiceError.missingHelper(.mkntfs)
            }
            try await privileged.run(
                formatter,
                arguments: ["-F", "-L", VolumeLabelFormatter.sanitizedFATLabel(volumeName), partition.deviceNode]
            )
        case .ext2:
            guard let formatter = toolchain.path(for: .mke2fs) else {
                throw FilesystemServiceError.missingHelper(.mke2fs)
            }
            try await privileged.run(
                formatter,
                arguments: ["-F", "-t", "ext2", "-L", volumeName, partition.deviceNode]
            )
        case .ext3:
            guard let formatter = toolchain.path(for: .mke2fs) else {
                throw FilesystemServiceError.missingHelper(.mke2fs)
            }
            try await privileged.run(
                formatter,
                arguments: ["-F", "-t", "ext3", "-L", volumeName, partition.deviceNode]
            )
        case .ext4:
            guard let formatter = toolchain.path(for: .mke2fs) else {
                throw FilesystemServiceError.missingHelper(.mke2fs)
            }
            try await privileged.run(
                formatter,
                arguments: ["-F", "-t", "ext4", "-L", volumeName, partition.deviceNode]
            )
        }
    }

    func sync() async {
        _ = try? await runner.run("/usr/bin/sync", arguments: [])
    }

    func finalizeNTFSPartition(
        partition: DiskPartition,
        ntfsfixPath: String
    ) async throws {
        try await privileged.run(
            ntfsfixPath,
            arguments: [partition.deviceNode]
        )
    }
}
