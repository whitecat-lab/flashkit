import Foundation

struct BundledToolchainService {
    private let runner: ProcessRunner
    private let resourceDirectoriesOverride: [URL]?

    init(
        runner: ProcessRunner = ProcessRunner(),
        resourceDirectoriesOverride: [URL]? = nil
    ) {
        self.runner = runner
        self.resourceDirectoriesOverride = resourceDirectoriesOverride
    }

    func detectToolchain() async -> ToolchainStatus {
        var tools: [HelperTool: ToolAvailability] = [:]

        for tool in HelperTool.allCases {
            let availability = await detectAvailability(for: tool)
            tools[tool] = availability
        }

        return ToolchainStatus(tools: tools)
    }

    func requirePath(for tool: HelperTool, in status: ToolchainStatus) throws -> String {
        if let path = status.path(for: tool) {
            return path
        }

        throw CocoaError(.fileNoSuchFile)
    }

    private func detectAvailability(for tool: HelperTool) async -> ToolAvailability {
        if tool == .uefiNTFSImage {
            return validateBundledAsset(for: tool, path: locateUEFINTFSImage())
        }

        if tool.isBundledRuntimeRequirement {
            return await validateBundledExecutable(for: tool, path: locateBundledExecutable(named: tool.rawValue))
        }

        return validateSystemTool(tool)
    }

    private func validateSystemTool(_ tool: HelperTool) -> ToolAvailability {
        guard let fallbackPath = knownSystemPath(for: tool) else {
            return missingAvailability(for: tool)
        }

        let isFile = FileManager.default.fileExists(atPath: fallbackPath)
        let isExecutable = FileManager.default.isExecutableFile(atPath: fallbackPath)
        guard isFile && isExecutable else {
            return missingAvailability(for: tool)
        }

        return ToolAvailability(
            tool: tool,
            path: fallbackPath,
            source: .system,
            validationState: .ready,
            validationMessage: nil
        )
    }

    private func validateBundledAsset(for tool: HelperTool, path: String?) -> ToolAvailability {
        guard let path else {
            return missingAvailability(for: tool)
        }

        let fileURL = URL(fileURLWithPath: path)
        let fileSize = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard fileSize > 0 else {
            return ToolAvailability(
                tool: tool,
                path: path,
                source: .bundled,
                validationState: .broken,
                validationMessage: "\(tool.userFacingName) is present in the app bundle but failed validation."
            )
        }

        return ToolAvailability(
            tool: tool,
            path: path,
            source: .bundled,
            validationState: .ready,
            validationMessage: nil
        )
    }

    private func validateBundledExecutable(for tool: HelperTool, path: String?) async -> ToolAvailability {
        guard let path else {
            return missingAvailability(for: tool)
        }

        guard FileManager.default.isExecutableFile(atPath: path) else {
            return ToolAvailability(
                tool: tool,
                path: path,
                source: .bundled,
                validationState: .broken,
                validationMessage: "\(tool.userFacingName) is present in the app bundle but is not executable."
            )
        }

        if let arguments = tool.validationArguments {
            do {
                _ = try await runner.run(path, arguments: arguments)
            } catch {
                return ToolAvailability(
                    tool: tool,
                    path: path,
                    source: .bundled,
                    validationState: .broken,
                    validationMessage: "\(tool.userFacingName) is bundled, but its startup validation failed."
                )
            }
        }

        return ToolAvailability(
            tool: tool,
            path: path,
            source: .bundled,
            validationState: .ready,
            validationMessage: nil
        )
    }

    private func missingAvailability(for tool: HelperTool) -> ToolAvailability {
        ToolAvailability(
            tool: tool,
            path: nil,
            source: .missing,
            validationState: .missing,
            validationMessage: nil
        )
    }

    private func locateBundledExecutable(named name: String) -> String? {
        for directory in resourceDirectories() {
            let candidate = directory.appending(path: "Helpers").appending(path: name)
            if FileManager.default.fileExists(atPath: candidate.path()) {
                return candidate.path()
            }
        }

        return nil
    }

    private func locateUEFINTFSImage() -> String? {
        for directory in resourceDirectories() {
            let candidate = directory.appending(path: "UEFI").appending(path: "uefi-ntfs.img")
            if FileManager.default.fileExists(atPath: candidate.path()) {
                return candidate.path()
            }
        }

        return nil
    }

    private func resourceDirectories() -> [URL] {
        if let resourceDirectoriesOverride {
            return uniqueURLs(resourceDirectoriesOverride)
        }

        var urls: [URL] = []
        let current = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        urls.append(current.appending(path: "Resources"))

        if let bundleResources = Bundle.main.resourceURL {
            urls.append(bundleResources)
        }

        if let executableURL = Bundle.main.executableURL {
            let contents = executableURL.deletingLastPathComponent().deletingLastPathComponent()
            urls.append(contents.appending(path: "Resources"))
        }

        return uniqueURLs(urls)
    }

    private func knownSystemPath(for tool: HelperTool) -> String? {
        switch tool {
        case .diskutil:
            return "/usr/sbin/diskutil"
        case .hdiutil:
            return "/usr/bin/hdiutil"
        case .dd:
            return "/bin/dd"
        case .newfsMsdos:
            return "/sbin/newfs_msdos"
        case .newfsUdf:
            return "/sbin/newfs_udf"
        case .shasum:
            return "/usr/bin/shasum"
        case .wimlibImagex, .uefiNTFSImage, .qemuImg, .mkntfs, .ntfsPopulateHelper, .ntfsfix, .mke2fs, .debugfs, .freedosBootHelper, .xz:
            return nil
        }
    }

    private func uniqueURLs(_ urls: [URL]) -> [URL] {
        var seen: Set<String> = []
        return urls.filter { url in
            let key = url.standardizedFileURL.path()
            return seen.insert(key).inserted
        }
    }
}
