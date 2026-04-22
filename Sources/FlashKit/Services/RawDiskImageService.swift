import Foundation

enum RawDiskCompression: String, Sendable {
    case gzip
    case xz
    case bzip2

    var displayName: String {
        switch self {
        case .gzip:
            return "gzip"
        case .xz:
            return "xz"
        case .bzip2:
            return "bzip2"
        }
    }
}

struct StreamedDecompressionCommand: Sendable {
    let compression: RawDiskCompression
    let executable: String
    let arguments: [String]
    let logicalSizeHint: Int64?

    var shellCommand: String {
        ([executable] + arguments).map(\.shellQuoted).joined(separator: " ")
    }
}

enum RawWriteInput: Sendable {
    case file(URL)
    case streamed(StreamedDecompressionCommand)

    var streamingCompression: RawDiskCompression? {
        switch self {
        case .file:
            return nil
        case let .streamed(command):
            return command.compression
        }
    }

    var logicalSizeHint: Int64? {
        switch self {
        case let .file(url):
            return (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
        case let .streamed(command):
            return command.logicalSizeHint
        }
    }
}

enum RawDiskImageServiceError: LocalizedError {
    case unsupportedCompressedImage
    case missingHelper(HelperTool)
    case emptyPreparedImage

    var errorDescription: String? {
        switch self {
        case .unsupportedCompressedImage:
            return "Only .img.gz, .img.xz, .img.bz2, .raw.gz, .raw.xz, and .raw.bz2 are supported compressed raw images."
        case let .missingHelper(tool):
            return "The helper \(tool.rawValue) is required to prepare this compressed raw image."
        case .emptyPreparedImage:
            return "The compressed raw image did not produce a readable temporary .img file."
        }
    }
}

struct PreparedRawDiskImage: Sendable {
    let resolvedURL: URL
    let cleanup: @Sendable () -> Void
}

struct RawDiskImageService {
    private let runner = ProcessRunner()

    static func compression(for sourceURL: URL) -> RawDiskCompression? {
        let lowercasedName = sourceURL.lastPathComponent.lowercased()

        if lowercasedName.hasSuffix(".img.gz") || lowercasedName.hasSuffix(".raw.gz") {
            return .gzip
        }

        if lowercasedName.hasSuffix(".img.xz") || lowercasedName.hasSuffix(".raw.xz") {
            return .xz
        }

        if lowercasedName.hasSuffix(".img.bz2") || lowercasedName.hasSuffix(".raw.bz2") {
            return .bzip2
        }

        return nil
    }

    static func isPlainRawImage(_ sourceURL: URL) -> Bool {
        let lowercasedName = sourceURL.lastPathComponent.lowercased()
        return lowercasedName.hasSuffix(".img") || lowercasedName.hasSuffix(".raw")
    }

    static func isSupportedRawImage(_ sourceURL: URL) -> Bool {
        isPlainRawImage(sourceURL) || compression(for: sourceURL) != nil
    }

    static func hasCompressedExtension(_ sourceURL: URL) -> Bool {
        let lowercasedName = sourceURL.lastPathComponent.lowercased()
        return lowercasedName.hasSuffix(".gz") || lowercasedName.hasSuffix(".xz") || lowercasedName.hasSuffix(".bz2")
    }

    func logicalSize(for sourceURL: URL) async -> Int64? {
        switch Self.compression(for: sourceURL) {
        case .gzip:
            return await gzipLogicalSize(for: sourceURL)
        case .xz:
            return await xzLogicalSize(for: sourceURL)
        case .bzip2:
            return await bzip2LogicalSize(for: sourceURL)
        case nil:
            return nil
        }
    }

    func preparationNote(for sourceURL: URL) -> String? {
        guard let compression = Self.compression(for: sourceURL) else {
            return nil
        }

        return "This \(compression.displayName)-compressed raw image will be streamed directly into the target device during writing."
    }

    func writeInput(
        for sourceURL: URL,
        toolchain: ToolchainStatus,
        preferStreaming: Bool = true
    ) async throws -> RawWriteInput {
        guard let compression = Self.compression(for: sourceURL) else {
            return .file(sourceURL)
        }

        _ = preferStreaming

        return .streamed(
            try await streamedDecompressionCommand(for: sourceURL, compression: compression, toolchain: toolchain)
        )
    }

    func prepareForWrite(
        sourceURL: URL,
        toolchain: ToolchainStatus
    ) async throws -> PreparedRawDiskImage {
        guard let compression = Self.compression(for: sourceURL) else {
            return PreparedRawDiskImage(resolvedURL: sourceURL, cleanup: {})
        }

        let preparedURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("img")

        do {
            switch compression {
            case .gzip:
                _ = try await runner.run(
                    "/bin/sh",
                    arguments: [
                        "-c",
                        "exec /usr/bin/gunzip -c \"$1\" > \"$2\"",
                        "sh",
                        sourceURL.path(),
                        preparedURL.path(),
                    ]
                )
            case .xz:
                guard let xzPath = toolchain.path(for: .xz) else {
                    throw RawDiskImageServiceError.missingHelper(.xz)
                }
                _ = try await runner.run(
                    "/bin/sh",
                    arguments: [
                        "-c",
                        "exec \"$1\" -dc \"$2\" > \"$3\"",
                        "sh",
                        xzPath,
                        sourceURL.path(),
                        preparedURL.path(),
                    ]
                )
            case .bzip2:
                _ = try await runner.run(
                    "/bin/sh",
                    arguments: [
                        "-c",
                        "exec /usr/bin/bzip2 -dc \"$1\" > \"$2\"",
                        "sh",
                        sourceURL.path(),
                        preparedURL.path(),
                    ]
                )
            }
        } catch {
            try? FileManager.default.removeItem(at: preparedURL)
            throw error
        }

        let preparedSize = (try? preparedURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        guard preparedSize > 0 else {
            try? FileManager.default.removeItem(at: preparedURL)
            throw RawDiskImageServiceError.emptyPreparedImage
        }

        return PreparedRawDiskImage(
            resolvedURL: preparedURL,
            cleanup: {
                try? FileManager.default.removeItem(at: preparedURL)
            }
        )
    }

    private func gzipLogicalSize(for sourceURL: URL) async -> Int64? {
        guard let lastDataLine = try? await runner.run("/usr/bin/gzip", arguments: ["-l", sourceURL.path()]).standardOutputText
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .reversed()
            .first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !$0.contains("compressed uncompressed") })
        else {
            return nil
        }

        let columns = lastDataLine.split(whereSeparator: \.isWhitespace)
        guard columns.count >= 2 else {
            return nil
        }

        return Int64(columns[1])
    }

    private func xzLogicalSize(for sourceURL: URL) async -> Int64? {
        guard let xzPath = bundledXZPath(),
              let totalsLine = try? await runner.run(xzPath, arguments: ["--robot", "--list", sourceURL.path()]).standardOutputText
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .first(where: { $0.hasPrefix("totals\t") })
        else {
            return nil
        }

        let fields = totalsLine.split(separator: "\t")
        guard fields.count >= 5 else {
            return nil
        }

        return Int64(fields[4])
    }

    private func bzip2LogicalSize(for sourceURL: URL) async -> Int64? {
        guard let output = try? await runner.run(
            "/bin/sh",
            arguments: [
                "-c",
                "exec /usr/bin/bzip2 -dc \"$1\" | /usr/bin/wc -c",
                "sh",
                sourceURL.path(),
            ]
        ).standardOutputText.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return nil
        }

        return Int64(output)
    }

    private func streamedDecompressionCommand(
        for sourceURL: URL,
        compression: RawDiskCompression,
        toolchain: ToolchainStatus
    ) async throws -> StreamedDecompressionCommand {
        switch compression {
        case .gzip:
            return StreamedDecompressionCommand(
                compression: .gzip,
                executable: "/usr/bin/gunzip",
                arguments: ["-c", sourceURL.path()],
                logicalSizeHint: await gzipLogicalSize(for: sourceURL)
            )
        case .xz:
            guard let xzPath = toolchain.path(for: .xz) else {
                throw RawDiskImageServiceError.missingHelper(.xz)
            }
            return StreamedDecompressionCommand(
                compression: .xz,
                executable: xzPath,
                arguments: ["-dc", sourceURL.path()],
                logicalSizeHint: await xzLogicalSize(for: sourceURL)
            )
        case .bzip2:
            return StreamedDecompressionCommand(
                compression: .bzip2,
                executable: "/usr/bin/bzip2",
                arguments: ["-dc", sourceURL.path()],
                logicalSizeHint: await bzip2LogicalSize(for: sourceURL)
            )
        }
    }

    private func bundledXZPath() -> String? {
        let fileManager = FileManager.default
        var directories: [URL] = [URL(fileURLWithPath: fileManager.currentDirectoryPath).appending(path: "Resources")]

        if let resourceURL = Bundle.main.resourceURL {
            directories.append(resourceURL)
        }

        if let executableURL = Bundle.main.executableURL {
            directories.append(
                executableURL
                    .deletingLastPathComponent()
                    .deletingLastPathComponent()
                    .appending(path: "Resources")
            )
        }

        for directory in directories {
            let candidate = directory.appending(path: "Helpers").appending(path: HelperTool.xz.rawValue)
            if fileManager.isExecutableFile(atPath: candidate.path()) {
                return candidate.path()
            }
        }

        return nil
    }
}
