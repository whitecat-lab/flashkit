import Foundation

struct CountedFileCopyManifest: Sendable {
    let directories: [String]
    let files: [CountedFileCopyEntry]
    let totalBytes: Int64
}

struct CountedFileCopyEntry: Sendable {
    let sourceURL: URL
    let relativePath: String
    let size: Int64
}

struct CountedFileCopyService {
    func manifest(from root: URL, skippingRelativePaths: [String]) throws -> CountedFileCopyManifest {
        let fileManager = FileManager.default
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .fileSizeKey]
        let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])
        let normalizedSkips = Set(skippingRelativePaths.map { $0.lowercased() })

        var directories: [String] = []
        var files: [CountedFileCopyEntry] = []
        var totalBytes: Int64 = 0

        while let item = enumerator?.nextObject() as? URL {
            let relativePath = relativePath(for: item, under: root)
            let candidate = relativePath.lowercased()

            if normalizedSkips.contains(candidate) {
                continue
            }

            let values = try item.resourceValues(forKeys: keys)
            if values.isDirectory == true {
                directories.append(relativePath)
                continue
            }

            let size = Int64(values.fileSize ?? 0)
            totalBytes += size
            files.append(CountedFileCopyEntry(sourceURL: item, relativePath: relativePath, size: size))
        }

        return CountedFileCopyManifest(
            directories: directories.sorted(),
            files: files.sorted { $0.relativePath < $1.relativePath },
            totalBytes: totalBytes
        )
    }

    func manifest(from files: [URL], relativeTo root: URL) throws -> CountedFileCopyManifest {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .fileSizeKey]
        var entries: [CountedFileCopyEntry] = []
        var totalBytes: Int64 = 0

        for file in files {
            let values = try file.resourceValues(forKeys: keys)
            guard values.isDirectory != true else {
                continue
            }
            let size = Int64(values.fileSize ?? 0)
            totalBytes += size
            entries.append(
                CountedFileCopyEntry(
                    sourceURL: file,
                    relativePath: relativePath(for: file, under: root),
                    size: size
                )
            )
        }

        return CountedFileCopyManifest(directories: [], files: entries.sorted { $0.relativePath < $1.relativePath }, totalBytes: totalBytes)
    }

    func copyManifest(
        _ manifest: CountedFileCopyManifest,
        to destinationRoot: URL,
        progress: @escaping @Sendable (Int64, Int64, String) async -> Void
    ) async throws {
        let fileManager = FileManager.default
        let totalBytes = max(manifest.totalBytes, 1)
        var copiedBytes: Int64 = 0

        for directory in manifest.directories {
            try Task.checkCancellation()
            try fileManager.createDirectory(at: destinationRoot.appending(path: directory), withIntermediateDirectories: true)
        }

        for file in manifest.files {
            try Task.checkCancellation()
            let destinationURL = destinationRoot.appending(path: file.relativePath)
            try fileManager.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: destinationURL.path()) {
                try fileManager.removeItem(at: destinationURL)
            }

            let startingCopiedBytes = copiedBytes
            try await copyFile(from: file.sourceURL, to: destinationURL) { bytesForFile in
                let absolute = startingCopiedBytes + bytesForFile
                await progress(absolute, totalBytes, "Copying \(file.relativePath)")
            }

            copiedBytes += file.size
            let permissions = (try? fileManager.attributesOfItem(atPath: file.sourceURL.path())[.posixPermissions] as? NSNumber)?.intValue ?? 0o644
            try? fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: destinationURL.path())
        }
    }

    private func copyFile(
        from sourceURL: URL,
        to destinationURL: URL,
        progress: @escaping @Sendable (Int64) async -> Void
    ) async throws {
        let sourceHandle = try FileHandle(forReadingFrom: sourceURL)
        FileManager.default.createFile(atPath: destinationURL.path(), contents: nil)
        let destinationHandle = try FileHandle(forWritingTo: destinationURL)
        defer {
            try? sourceHandle.close()
            try? destinationHandle.close()
        }

        var copiedBytes: Int64 = 0
        while true {
            try Task.checkCancellation()
            let chunk = try sourceHandle.read(upToCount: 1024 * 1024) ?? Data()
            if chunk.isEmpty {
                break
            }
            try destinationHandle.write(contentsOf: chunk)
            copiedBytes += Int64(chunk.count)
            await progress(copiedBytes)
        }
    }

    private func relativePath(for url: URL, under root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let fullPath = url.standardizedFileURL.path
        if fullPath.hasPrefix(rootPath + "/") {
            return String(fullPath.dropFirst(rootPath.count + 1))
        }
        return url.lastPathComponent
    }
}
