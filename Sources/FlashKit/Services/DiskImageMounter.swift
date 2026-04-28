import Foundation

enum DiskImageMounterError: LocalizedError {
    case mountPointUnavailable

    var errorDescription: String? {
        switch self {
        case .mountPointUnavailable:
            return "The mounted image did not expose a usable mount point."
        }
    }
}

struct MountedDiskImage: Sendable {
    let deviceEntry: String
    let mountPoint: URL
    let volumeName: String
}

protocol DiskImageMounting: Sendable {
    func mountImage(at imageURL: URL) async throws -> MountedDiskImage
    func detach(_ mountedImage: MountedDiskImage) async throws
}

struct DiskImageMounter: DiskImageMounting {
    private let runner = ProcessRunner()

    func mountImage(at imageURL: URL) async throws -> MountedDiskImage {
        let result = try await runner.run(
            "/usr/bin/hdiutil",
            arguments: ["attach", "-plist", "-readonly", "-nobrowse", imageURL.path]
        )
        let plist = try PropertyListLoader.dictionary(from: result.standardOutput)
        let entities = plist["system-entities"] as? [[String: Any]] ?? []

        guard
            let mountedEntity = entities.first(where: { entity in
                if let mountPoint = entity["mount-point"] as? String {
                    return !mountPoint.isEmpty
                }

                return false
            }),
            let mountPoint = mountedEntity["mount-point"] as? String
        else {
            throw DiskImageMounterError.mountPointUnavailable
        }

        let mountURL = URL(fileURLWithPath: mountPoint)
        return MountedDiskImage(
            deviceEntry: mountedEntity["dev-entry"] as? String ?? mountPoint,
            mountPoint: mountURL,
            volumeName: mountURL.lastPathComponent
        )
    }

    func detach(_ mountedImage: MountedDiskImage) async throws {
        do {
            _ = try await runner.run(
                "/usr/bin/hdiutil",
                arguments: ["detach", mountedImage.deviceEntry]
            )
        } catch {
            _ = try await runner.run(
                "/usr/bin/hdiutil",
                arguments: ["detach", "-force", mountedImage.deviceEntry]
            )
        }
    }
}
