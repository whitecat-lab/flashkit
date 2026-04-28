import Foundation

enum VerificationDestination: Sendable {
    case file(URL)
    case device(String)
}

enum VerificationServiceError: LocalizedError {
    case missingFile(String)
    case mismatch(String)
    case unreadable(String)
    case destinationUnavailable(String)

    var errorDescription: String? {
        switch self {
        case let .missingFile(path):
            return "Verification could not find \(path) on the destination."
        case let .mismatch(message):
            return message
        case let .unreadable(message):
            return message
        case let .destinationUnavailable(message):
            return message
        }
    }
}

struct VerificationService {
    private let privileged = PrivilegedCommandService()
    private let runner = ProcessRunner()
    private let blockSize: Int64 = 1_048_576

    func verifyWindowsInstaller(
        sourceRoot: URL,
        destinationRoot: URL,
        profile: SourceImageProfile,
        plan: WritePlan,
        customization: CustomizationProfile
    ) async throws {
        let skippedInstallPath = plan.payloadMode == .fat32SplitWim ? profile.windows?.installImageRelativePath : nil
        try verifyCopiedManifest(sourceRoot: sourceRoot, destinationRoot: destinationRoot, skippingRelativePath: skippedInstallPath)

        if plan.payloadMode == .fat32SplitWim,
           let installPath = profile.windows?.installImageRelativePath {
            let splitPrefix = ((installPath as NSString).deletingPathExtension as NSString).lastPathComponent.lowercased()
            let splitDirectory = destinationRoot.appending(path: ((installPath as NSString).deletingLastPathComponent))
            let splitExists = (try? FileManager.default.contentsOfDirectory(atPath: splitDirectory.path()).contains(where: { file in
                let lowercased = file.lowercased()
                return lowercased.hasPrefix(splitPrefix) && lowercased.hasSuffix(".swm")
            })) ?? false
            guard splitExists else {
                throw VerificationServiceError.missingFile(swmPath(for: installPath))
            }
        }

        for artifactPath in requiredArtifactPaths(for: profile, plan: plan, customization: customization) {
            guard existingURL(in: destinationRoot, relativePath: artifactPath) != nil else {
                throw VerificationServiceError.missingFile(artifactPath)
            }
        }
    }

    func verifyCopiedManifest(
        sourceRoot: URL,
        destinationRoot: URL,
        skippingRelativePath: String? = nil
    ) throws {
        let manifest = try buildManifest(from: sourceRoot, skippingRelativePath: skippingRelativePath)

        for entry in manifest.files {
            let destinationURL = destinationRoot.appending(path: entry.relativePath)
            guard FileManager.default.fileExists(atPath: destinationURL.path()) else {
                throw VerificationServiceError.missingFile(entry.relativePath)
            }
            try compareStreams(
                referenceURL: entry.url,
                destination: .file(destinationURL),
                limit: entry.size,
                label: entry.relativePath
            )
        }
    }

    func verifyWindowsInstallerOnNTFS(
        sourceRoot: URL,
        destinationPartition: DiskPartition,
        profile: SourceImageProfile,
        plan: WritePlan,
        customization: CustomizationProfile,
        toolchain: ToolchainStatus,
        ntfsPopulateService: NTFSPopulateService
    ) async throws {
        let manifest = try buildManifest(from: sourceRoot, skippingRelativePath: nil)

        for entry in manifest.files {
            try await ntfsPopulateService.verifyFile(
                from: destinationPartition,
                referenceURL: entry.url,
                relativePath: entry.relativePath,
                toolchain: toolchain
            )
        }

        for artifactPath in requiredArtifactPaths(for: profile, plan: plan, customization: customization) {
            try await ntfsPopulateService.assertFileExists(
                on: destinationPartition,
                relativePath: artifactPath,
                toolchain: toolchain
            )
        }
    }

    func verifyWrittenImage(
        referenceURL: URL,
        destinationDeviceNode: String,
        expectedBytes: Int64? = nil
    ) async throws {
        do {
            try compareStreams(
                referenceURL: referenceURL,
                destination: .device(destinationDeviceNode),
                limit: expectedBytes ?? fileSize(of: referenceURL),
                label: referenceURL.lastPathComponent
            )
            return
        } catch VerificationServiceError.unreadable {
            // Fall back to a privileged mirror for environments where the app
            // does not own the device node.
        }

        let destinationURL = try await stagedURL(for: .device(destinationDeviceNode), expectedBytes: expectedBytes ?? fileSize(of: referenceURL))
        defer { try? FileManager.default.removeItem(at: destinationURL) }
        try compareStreams(
            referenceURL: referenceURL,
            destination: .file(destinationURL),
            limit: expectedBytes ?? fileSize(of: referenceURL),
            label: referenceURL.lastPathComponent
        )
    }

    func verifyWrittenRawInput(
        _ input: RawWriteInput,
        destinationDeviceNode: String
    ) async throws {
        switch input {
        case let .file(url):
            try await verifyWrittenImage(
                referenceURL: url,
                destinationDeviceNode: destinationDeviceNode,
                expectedBytes: input.logicalSizeHint
            )
        case let .streamed(command):
            guard let expectedBytes = command.logicalSizeHint else {
                throw VerificationServiceError.destinationUnavailable(
                    "Verification could not determine the uncompressed size of the streamed \(command.compression.displayName) image."
                )
            }

            let destinationURL = try await stagedURL(for: .device(destinationDeviceNode), expectedBytes: expectedBytes)
            defer { try? FileManager.default.removeItem(at: destinationURL) }
            try await compareStreamedSource(
                command,
                destinationURL: destinationURL,
                limit: expectedBytes,
                label: command.compression.displayName
            )
        }
    }

    func verifyCapturedImage(
        sourceDeviceNode: String,
        destinationURL: URL,
        expectedBytes: Int64
    ) async throws {
        let mirroredSource = try await stagedURL(for: .device(sourceDeviceNode), expectedBytes: expectedBytes)
        defer { try? FileManager.default.removeItem(at: mirroredSource) }
        try compareStreams(referenceURL: mirroredSource, destination: .file(destinationURL), limit: expectedBytes, label: destinationURL.lastPathComponent)
    }

    func verifyVHDXCapture(
        sourceDeviceNode: String,
        destinationURL: URL,
        expectedBytes: Int64,
        qemuImg: String
    ) async throws {
        try await verifyQEMUConvertedCapture(
            sourceDeviceNode: sourceDeviceNode,
            destinationURL: destinationURL,
            expectedBytes: expectedBytes,
            qemuImg: qemuImg
        )
    }

    func verifyQEMUConvertedCapture(
        sourceDeviceNode: String,
        destinationURL: URL,
        expectedBytes: Int64,
        qemuImg: String
    ) async throws {
        let mirroredSource = try await stagedURL(for: .device(sourceDeviceNode), expectedBytes: expectedBytes)
        defer { try? FileManager.default.removeItem(at: mirroredSource) }

        let convertedRaw = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("img")
        defer { try? FileManager.default.removeItem(at: convertedRaw) }

        _ = try await runner.run(qemuImg, arguments: ["convert", "-O", "raw", destinationURL.path(), convertedRaw.path()])
        try compareStreams(referenceURL: mirroredSource, destination: .file(convertedRaw), limit: expectedBytes, label: destinationURL.lastPathComponent)
    }

    private func buildManifest(from root: URL, skippingRelativePath: String?) throws -> VerificationManifest {
        let fileManager = FileManager.default
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .fileSizeKey]
        let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])
        let normalizedSkip = skippingRelativePath?.lowercased()

        var files: [VerificationEntry] = []

        while let item = enumerator?.nextObject() as? URL {
            let values = try item.resourceValues(forKeys: keys)
            guard values.isDirectory != true else {
                continue
            }

            let relativePath = relativePath(for: item, under: root)
            if let normalizedSkip, relativePath.lowercased() == normalizedSkip {
                continue
            }

            files.append(
                VerificationEntry(
                    relativePath: relativePath,
                    url: item,
                    size: Int64(values.fileSize ?? 0)
                )
            )
        }

        return VerificationManifest(files: files.sorted { $0.relativePath < $1.relativePath })
    }

    private func requiredArtifactPaths(
        for profile: SourceImageProfile,
        plan: WritePlan,
        customization: CustomizationProfile
    ) -> Set<String> {
        var artifacts: Set<String> = []

        if plan.postWriteFixups.contains(.windows7EFIFallback) {
            artifacts.insert("efi/boot/bootx64.efi")
        }

        if plan.postWriteFixups.contains(.biosWinPEFixup) {
            artifacts.insert("BOOTMGR".lowercased())
            artifacts.insert("ntdetect.com")
            if profile.windows?.isWinPE == true {
                artifacts.insert("txtsetup.sif")
            }
        }

        if customization.isEnabled && profile.windows?.hasPantherUnattend != true {
            artifacts.insert(customization.preferredPlacement.relativePath.lowercased())
        }

        return artifacts
    }

    private func compareStreams(
        referenceURL: URL,
        destination: VerificationDestination,
        limit: Int64,
        label: String
    ) throws {
        let destinationURL = switch destination {
        case let .file(url):
            url
        case let .device(deviceNode):
            URL(fileURLWithPath: deviceNode)
        }

        let referenceHandle = try FileHandle(forReadingFrom: referenceURL)
        defer { try? referenceHandle.close() }

        let destinationHandle: FileHandle
        do {
            destinationHandle = try FileHandle(forReadingFrom: destinationURL)
        } catch {
            throw VerificationServiceError.unreadable("Verification could not read \(label) from the destination.")
        }
        defer { try? destinationHandle.close() }

        var remaining = limit
        while remaining > 0 {
            let chunkSize = Int(min(blockSize, remaining))
            let referenceChunk = try referenceHandle.read(upToCount: chunkSize) ?? Data()
            let destinationChunk = try destinationHandle.read(upToCount: chunkSize) ?? Data()

            if referenceChunk != destinationChunk {
                throw VerificationServiceError.mismatch("Verification failed for \(label): the destination content did not match the source image.")
            }

            remaining -= Int64(referenceChunk.count)
            if referenceChunk.isEmpty && remaining > 0 {
                throw VerificationServiceError.mismatch("Verification failed for \(label): the destination ended before the source data did.")
            }
        }
    }

    private func compareStreamedSource(
        _ command: StreamedDecompressionCommand,
        destinationURL: URL,
        limit: Int64,
        label: String
    ) async throws {
        let process = Process()
        let standardOutput = Pipe()
        let standardError = Pipe()

        process.executableURL = URL(fileURLWithPath: command.executable)
        process.arguments = command.arguments
        process.standardOutput = standardOutput
        process.standardError = standardError

        let destinationHandle: FileHandle
        do {
            destinationHandle = try FileHandle(forReadingFrom: destinationURL)
        } catch {
            throw VerificationServiceError.unreadable("Verification could not read the destination bytes for the streamed \(label) image.")
        }
        defer { try? destinationHandle.close() }

        do {
            try process.run()
        } catch {
            throw VerificationServiceError.unreadable("Verification could not start the streamed \(label) decompression command.")
        }

        let sourceHandle = standardOutput.fileHandleForReading
        defer { try? sourceHandle.close() }

        var remaining = limit
        while remaining > 0 {
            let chunkSize = Int(min(blockSize, remaining))
            let sourceChunk = try sourceHandle.read(upToCount: chunkSize) ?? Data()
            let destinationChunk = try destinationHandle.read(upToCount: chunkSize) ?? Data()

            if sourceChunk != destinationChunk {
                process.terminate()
                throw VerificationServiceError.mismatch(
                    "Verification failed for the streamed \(label) image: the destination content did not match the source stream."
                )
            }

            remaining -= Int64(sourceChunk.count)
            if sourceChunk.isEmpty && remaining > 0 {
                process.terminate()
                throw VerificationServiceError.mismatch(
                    "Verification failed for the streamed \(label) image: the decompressed source ended before the destination compare completed."
                )
            }
        }

        process.waitUntilExit()
        let errorText = String(decoding: standardError.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0 else {
            throw VerificationServiceError.unreadable(
                errorText.isEmpty
                    ? "Verification failed while streaming the \(label) image."
                    : "Verification failed while streaming the \(label) image: \(errorText)"
            )
        }
    }

    private func stagedURL(for destination: VerificationDestination, expectedBytes: Int64) async throws -> URL {
        switch destination {
        case let .file(url):
            return url
        case let .device(deviceNode):
            let stagingURL = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("img")
            let blockCount = Int((expectedBytes + blockSize - 1) / blockSize)
            try await runPrivilegedDD(input: deviceNode, output: stagingURL.path(), count: blockCount)
            return stagingURL
        }
    }

    private func runPrivilegedDD(input: String, output: String, count: Int) async throws {
        _ = try await privileged.run(
            "/bin/dd",
            arguments: [
                "if=\(input)",
                "of=\(output)",
                "bs=\(blockSize)",
                "count=\(count)",
                "conv=sync",
            ]
        )
    }

    private func fileSize(of url: URL) -> Int64 {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize.map(Int64.init)) ?? 0
    }

    private func swmPath(for relativePath: String) -> String {
        let base = (relativePath as NSString).deletingPathExtension
        return "\(base).swm".lowercased()
    }

    private func existingURL(in root: URL, relativePath: String) -> URL? {
        let fileManager = FileManager.default
        var current = root

        for component in relativePath.split(separator: "/").map(String.init) {
            guard let childName = try? fileManager.contentsOfDirectory(atPath: current.path()).first(where: { $0.caseInsensitiveCompare(component) == .orderedSame }) else {
                return nil
            }
            current.append(path: childName)
        }

        return current
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

private struct VerificationManifest {
    let files: [VerificationEntry]
}

private struct VerificationEntry {
    let relativePath: String
    let url: URL
    let size: Int64
}
