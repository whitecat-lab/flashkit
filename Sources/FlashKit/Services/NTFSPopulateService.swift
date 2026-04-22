import FlashKitHelperProtocol
import Foundation

enum NTFSPopulateServiceError: LocalizedError {
    case missingHelper(HelperTool)

    var errorDescription: String? {
        switch self {
        case let .missingHelper(tool):
            return "\(tool.userFacingName) is required for NTFS Windows media."
        }
    }
}

struct NTFSPopulateService {
    private let privileged = PrivilegedCommandService()
    private let runner = ProcessRunner()

    func copyContents(
        from sourceRoot: URL,
        to partition: DiskPartition,
        skippingRelativePath: String?,
        toolchain: ToolchainStatus,
        eventHandler: PrivilegedWorkerEventHandler? = nil
    ) async throws {
        guard let helper = toolchain.path(for: .ntfsPopulateHelper) else {
            throw NTFSPopulateServiceError.missingHelper(.ntfsPopulateHelper)
        }

        var arguments = [
            "copy",
            "--device", partition.deviceNode,
            "--source", sourceRoot.path(),
        ]
        if let skippingRelativePath, !skippingRelativePath.isEmpty {
            arguments += ["--skip-relative-path", skippingRelativePath]
        }

        let totalBytes = try totalBytesForCopy(from: sourceRoot, skippingRelativePath: skippingRelativePath)
        _ = try await privileged.run(
            helper,
            arguments: arguments,
            progressParser: .ntfsPopulate,
            expectedTotalBytes: totalBytes,
            phase: "Copying files",
            message: "Populating the NTFS installer payload.",
            eventHandler: eventHandler
        )
    }

    func verifyFile(
        from partition: DiskPartition,
        referenceURL: URL,
        relativePath: String,
        toolchain: ToolchainStatus
    ) async throws {
        guard let helper = toolchain.path(for: .ntfsPopulateHelper) else {
            throw NTFSPopulateServiceError.missingHelper(.ntfsPopulateHelper)
        }

        _ = try await runner.run(
            helper,
            arguments: [
                "verify-file",
                "--device", partition.deviceNode,
                "--reference", referenceURL.path(),
                "--path", relativePath,
            ]
        )
    }

    func assertFileExists(
        on partition: DiskPartition,
        relativePath: String,
        toolchain: ToolchainStatus
    ) async throws {
        guard let helper = toolchain.path(for: .ntfsPopulateHelper) else {
            throw NTFSPopulateServiceError.missingHelper(.ntfsPopulateHelper)
        }

        _ = try await runner.run(
            helper,
            arguments: [
                "exists",
                "--device", partition.deviceNode,
                "--path", relativePath,
            ]
        )
    }

    private func totalBytesForCopy(from sourceRoot: URL, skippingRelativePath: String?) throws -> Int64 {
        let fileManager = FileManager.default
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .fileSizeKey]
        let enumerator = fileManager.enumerator(at: sourceRoot, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])
        let normalizedSkip = skippingRelativePath?.lowercased()
        var totalBytes: Int64 = 0

        while let item = enumerator?.nextObject() as? URL {
            let relativePath = relativePathForCopy(from: item, under: sourceRoot)
            if normalizedSkip == relativePath.lowercased() {
                continue
            }

            let values = try item.resourceValues(forKeys: keys)
            if values.isDirectory == true {
                continue
            }

            totalBytes += Int64(values.fileSize ?? 0)
        }

        return totalBytes
    }

    private func relativePathForCopy(from url: URL, under root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let fullPath = url.standardizedFileURL.path
        if fullPath.hasPrefix(rootPath + "/") {
            return String(fullPath.dropFirst(rootPath.count + 1))
        }
        return url.lastPathComponent
    }
}
