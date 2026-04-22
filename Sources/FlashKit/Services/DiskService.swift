import Foundation

enum DiskServiceError: LocalizedError {
    case targetVolumeNotMounted(String)
    case partitionDeviceMissing(String)

    var errorDescription: String? {
        switch self {
        case let .targetVolumeNotMounted(identifier):
            return "The freshly formatted target volume on \(identifier) never mounted."
        case let .partitionDeviceMissing(identifier):
            return "The partition device \(identifier) could not be discovered."
        }
    }
}

struct DiskPartition: Identifiable, Sendable {
    let identifier: String
    let deviceNode: String
    let mountPoint: URL?

    var id: String { identifier }
}

struct DiskService {
    private let runner = ProcessRunner()

    func listExternalDisks() async throws -> [ExternalDisk] {
        let result = try await runner.run(
            "/usr/sbin/diskutil",
            arguments: ["list", "-plist", "external", "physical"]
        )
        let plist = try PropertyListLoader.dictionary(from: result.standardOutput)
        let identifiers = (plist["WholeDisks"] as? [String] ?? []).sorted()

        var disks: [ExternalDisk] = []

        for identifier in identifiers {
            let info = try await diskInfo(for: identifier)
            guard (info["WholeDisk"] as? Bool ?? false) else {
                continue
            }
            guard !(info["Internal"] as? Bool ?? true) else {
                continue
            }
            guard info["WritableMedia"] as? Bool ?? false else {
                continue
            }

            let disk = ExternalDisk(
                identifier: identifier,
                deviceNode: info["DeviceNode"] as? String ?? "/dev/\(identifier)",
                mediaName: info["MediaName"] as? String ?? identifier,
                volumeName: (info["VolumeName"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                size: PropertyListLoader.integer64(info["TotalSize"]) ?? PropertyListLoader.integer64(info["Size"]) ?? 0,
                busProtocol: info["BusProtocol"] as? String,
                removable: info["Removable"] as? Bool ?? (info["RemovableMedia"] as? Bool ?? false),
                ejectable: info["Ejectable"] as? Bool ?? false,
                writable: info["WritableMedia"] as? Bool ?? false
            )
            disks.append(disk)
        }

        return disks.sorted { lhs, rhs in
            if lhs.size == rhs.size {
                return lhs.identifier < rhs.identifier
            }

            return lhs.size < rhs.size
        }
    }

    func mountedVolumeURL(forWholeDisk identifier: String) async throws -> URL {
        for _ in 0..<20 {
            if let mounted = try await mountedPartitions(forWholeDisk: identifier).first(where: { $0.mountPoint != nil })?.mountPoint {
                return mounted
            }
            try await Task.sleep(for: .seconds(1))
        }

        throw DiskServiceError.targetVolumeNotMounted(identifier)
    }

    func mountedPartitions(forWholeDisk identifier: String) async throws -> [DiskPartition] {
        let result = try await runner.run(
            "/usr/sbin/diskutil",
            arguments: ["list", "-plist", identifier]
        )
        let plist = try PropertyListLoader.dictionary(from: result.standardOutput)
        let entries = plist["AllDisksAndPartitions"] as? [[String: Any]] ?? []
        let wholeDisk = entries.first { entry in
            entry["DeviceIdentifier"] as? String == identifier
        }
        let partitions = wholeDisk?["Partitions"] as? [[String: Any]] ?? []

        var resolved: [DiskPartition] = []
        for partition in partitions {
            guard let partitionIdentifier = partition["DeviceIdentifier"] as? String else {
                continue
            }

            let info = try await diskInfo(for: partitionIdentifier)
            let mountPoint = (info["MountPoint"] as? String).flatMap {
                $0.isEmpty ? nil : URL(fileURLWithPath: $0)
            }
            resolved.append(
                DiskPartition(
                    identifier: partitionIdentifier,
                    deviceNode: info["DeviceNode"] as? String ?? "/dev/\(partitionIdentifier)",
                    mountPoint: mountPoint
                )
            )
        }

        return resolved
    }

    func firstPartition(afterFormatting wholeDisk: String, matching filesystem: FilesystemType? = nil) async throws -> DiskPartition {
        for _ in 0..<20 {
            let partitions = try await mountedPartitions(forWholeDisk: wholeDisk)
            if let filesystem {
                for partition in partitions {
                    let info = try await diskInfo(for: partition.identifier)
                    let content = (info["FilesystemName"] as? String ?? info["FilesystemType"] as? String ?? "").lowercased()
                    if content.contains(filesystem.rawValue.lowercased()) {
                        return partition
                    }
                }
            } else if let first = partitions.first {
                return first
            }

            try await Task.sleep(for: .seconds(1))
        }

        throw DiskServiceError.partitionDeviceMissing(wholeDisk)
    }

    func diskInfo(for identifier: String) async throws -> [String: Any] {
        let result = try await runner.run(
            "/usr/sbin/diskutil",
            arguments: ["info", "-plist", identifier]
        )
        return try PropertyListLoader.dictionary(from: result.standardOutput)
    }
}
