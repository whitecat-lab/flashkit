import Foundation

enum WindowsInstallerPatchServiceError: LocalizedError {
    case missingWimlib
    case missingBootWIM
    case missingWinPELoader

    var errorDescription: String? {
        switch self {
        case .missingWimlib:
            return "wimlib-imagex is required for this Windows installer patch."
        case .missingBootWIM:
            return "The source boot.wim was not found for the Windows 7 EFI fallback patch."
        case .missingWinPELoader:
            return "The WinPE source did not contain the expected BIOS setup loader files."
        }
    }
}

struct WindowsInstallerPatchService {
    private let runner = ProcessRunner()

    func applyRequiredPatches(
        profile: SourceImageProfile,
        sourceRoot: URL,
        destinationRoot: URL?,
        ntfsDestinationPartition: DiskPartition?,
        plan: WritePlan,
        customization: CustomizationProfile,
        toolchain: ToolchainStatus,
        ntfsPopulateService: NTFSPopulateService
    ) async throws {
        guard let windows = profile.windows else {
            return
        }

        let patchRoot: URL
        let isTemporaryPatchRoot: Bool
        if let destinationRoot {
            patchRoot = destinationRoot
            isTemporaryPatchRoot = false
        } else {
            patchRoot = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: patchRoot, withIntermediateDirectories: true)
            isTemporaryPatchRoot = true
        }

        defer {
            if isTemporaryPatchRoot {
                try? FileManager.default.removeItem(at: patchRoot)
            }
        }

        if windows.needsWindows7EFIFallback {
            try await applyWindows7EFIFallback(sourceRoot: sourceRoot, destinationRoot: patchRoot, toolchain: toolchain)
        }

        if windows.requiresBIOSWinPEFixup {
            try applyBIOSWinPEFixup(sourceRoot: sourceRoot, destinationRoot: patchRoot)
        }

        try normalizeSetupBootArtifacts(sourceRoot: sourceRoot, destinationRoot: patchRoot)

        if customization.bypassSecureBootTPMRAMChecks {
            try applyWindows11BypassArtifacts(destinationRoot: patchRoot)
        }

        if isTemporaryPatchRoot, let ntfsDestinationPartition {
            try await ntfsPopulateService.copyContents(
                from: patchRoot,
                to: ntfsDestinationPartition,
                skippingRelativePath: nil,
                toolchain: toolchain
            )
        }

        _ = plan
    }

    private func normalizeSetupBootArtifacts(sourceRoot: URL, destinationRoot: URL) throws {
        try copyIfPresent(
            from: sourceRoot.appending(path: "efi").appending(path: "boot").appending(path: "bootx64.efi"),
            to: destinationRoot.appending(path: "EFI").appending(path: "BOOT").appending(path: "BOOTX64.EFI")
        )
        try copyIfPresent(
            from: sourceRoot.appending(path: "efi").appending(path: "boot").appending(path: "bootia32.efi"),
            to: destinationRoot.appending(path: "EFI").appending(path: "BOOT").appending(path: "BOOTIA32.EFI")
        )
        try copyIfPresent(
            from: sourceRoot.appending(path: "efi").appending(path: "boot").appending(path: "bootaa64.efi"),
            to: destinationRoot.appending(path: "EFI").appending(path: "BOOT").appending(path: "BOOTAA64.EFI")
        )
        try copyIfPresent(
            from: sourceRoot.appending(path: "bootmgr"),
            to: destinationRoot.appending(path: "BOOTMGR")
        )
        try copyIfPresent(
            from: sourceRoot.appending(path: "boot").appending(path: "bcd"),
            to: destinationRoot.appending(path: "boot").appending(path: "BCD")
        )
    }

    private func applyWindows11BypassArtifacts(destinationRoot: URL) throws {
        let sourcesDirectory = destinationRoot.appending(path: "sources")
        try FileManager.default.createDirectory(at: sourcesDirectory, withIntermediateDirectories: true)
        let appraiserURL = sourcesDirectory.appending(path: "appraiserres.dll")
        let backupURL = sourcesDirectory.appending(path: "appraiserres.dll.bak")
        let fileManager = FileManager.default

        if fileManager.fileExists(atPath: appraiserURL.path()), !fileManager.fileExists(atPath: backupURL.path()) {
            try fileManager.copyItem(at: appraiserURL, to: backupURL)
        }

        try Data().write(to: appraiserURL, options: .atomic)
    }

    private func applyWindows7EFIFallback(sourceRoot: URL, destinationRoot: URL, toolchain: ToolchainStatus) async throws {
        guard let wimlib = toolchain.path(for: .wimlibImagex) else {
            throw WindowsInstallerPatchServiceError.missingWimlib
        }

        let bootWIM = sourceRoot.appending(path: "sources").appending(path: "boot.wim")
        guard FileManager.default.fileExists(atPath: bootWIM.path()) else {
            throw WindowsInstallerPatchServiceError.missingBootWIM
        }

        let efiBootDirectory = destinationRoot.appending(path: "efi").appending(path: "boot")
        try FileManager.default.createDirectory(at: efiBootDirectory, withIntermediateDirectories: true)

        let tempOutput = efiBootDirectory.appending(path: "bootmgfw.efi")
        _ = try await runner.run(
            wimlib,
            arguments: [
                "extract",
                bootWIM.path(),
                "1",
                "Windows/Boot/EFI/bootmgfw.efi",
                "--dest-dir=\(efiBootDirectory.path())",
                "--no-acls",
                "--no-attributes",
            ]
        )

        let finalOutput = efiBootDirectory.appending(path: "bootx64.efi")
        if FileManager.default.fileExists(atPath: finalOutput.path()) {
            try FileManager.default.removeItem(at: finalOutput)
        }
        try FileManager.default.moveItem(at: tempOutput, to: finalOutput)
    }

    private func applyBIOSWinPEFixup(sourceRoot: URL, destinationRoot: URL) throws {
        let candidateDirectories = ["i386", "amd64", "minint"]
        let loaderDirectory = candidateDirectories.first { directory in
            FileManager.default.fileExists(atPath: sourceRoot.appending(path: directory).path())
        }
        guard let loaderDirectory else {
            throw WindowsInstallerPatchServiceError.missingWinPELoader
        }

        let preferredLegacyDirectory = loaderDirectory == "minint" ? "i386" : loaderDirectory
        try copyIfPresent(
            from: sourceRoot.appending(path: preferredLegacyDirectory).appending(path: "ntdetect.com"),
            to: destinationRoot.appending(path: "ntdetect.com")
        )
        try copyIfPresent(
            from: sourceRoot.appending(path: preferredLegacyDirectory).appending(path: "setupldr.bin"),
            to: destinationRoot.appending(path: "BOOTMGR")
        )
        try copyIfPresent(
            from: sourceRoot.appending(path: preferredLegacyDirectory).appending(path: "abortpxe.com"),
            to: destinationRoot.appending(path: "abortpxe.com")
        )
        try copyIfPresent(
            from: sourceRoot.appending(path: preferredLegacyDirectory).appending(path: "bootfont.bin"),
            to: destinationRoot.appending(path: "bootfont.bin")
        )
        try copyIfPresent(
            from: sourceRoot.appending(path: "boot").appending(path: "bootfix.bin"),
            to: destinationRoot.appending(path: "boot").appending(path: "bootfix.bin")
        )

        let txtsetupSource = sourceRoot.appending(path: preferredLegacyDirectory).appending(path: "txtsetup.sif")
        let txtsetupDestination = destinationRoot.appending(path: "txtsetup.sif")
        if FileManager.default.fileExists(atPath: txtsetupSource.path()) {
            try copyIfPresent(from: txtsetupSource, to: txtsetupDestination)
            try patchTxtsetup(at: txtsetupDestination)
        }

        let bootmgrURL = destinationRoot.appending(path: "BOOTMGR")
        if FileManager.default.fileExists(atPath: bootmgrURL.path()) {
            try patchSetupldrBinary(at: bootmgrURL, architectureDirectory: preferredLegacyDirectory)
        }
    }

    private func copyIfPresent(from source: URL, to destination: URL) throws {
        guard FileManager.default.fileExists(atPath: source.path()) else {
            return
        }

        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destination.path()) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: source, to: destination)
    }

    private func patchTxtsetup(at url: URL) throws {
        let setupSourceDevice = #"SetupSourceDevice = "\device\harddisk1\partition1""#
        var text = try String(contentsOf: url, encoding: .utf8)

        if !text.localizedCaseInsensitiveContains(setupSourceDevice) {
            if let range = text.range(of: "[SetupData]", options: .caseInsensitive) {
                let insertionIndex = text.index(range.upperBound, offsetBy: 0)
                text.insert(contentsOf: "\n\(setupSourceDevice)", at: insertionIndex)
            } else {
                text.append("\n[SetupData]\n\(setupSourceDevice)\n")
            }
        }

        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func patchSetupldrBinary(at url: URL, architectureDirectory: String) throws {
        var data = try Data(contentsOf: url)
        let replacements = [
            (pattern: #"\\minint\\txtsetup.sif"#, replacement: "\\\(architectureDirectory)\\txtsetup.sif"),
            (pattern: #"\\minint\\system32\\"#, replacement: "\\\(architectureDirectory)\\system32\\"),
            (pattern: "$WIN_NT$.~BT", replacement: architectureDirectory),
            (pattern: "rdisk(0)", replacement: "rdisk(1)"),
        ]

        for replacement in replacements {
            data = replaceASCII(in: data, pattern: replacement.pattern, replacement: replacement.replacement)
        }

        try data.write(to: url, options: .atomic)
    }

    private func replaceASCII(in data: Data, pattern: String, replacement: String) -> Data {
        guard let patternData = pattern.data(using: .ascii),
              let replacementData = replacement.padding(toLength: patternData.count, withPad: "\0", startingAt: 0).data(using: .ascii),
              patternData.count == replacementData.count else {
            return data
        }

        var mutable = data
        let limit = mutable.count - patternData.count
        guard limit >= 0 else {
            return mutable
        }

        for index in 0...limit {
            let range = index..<(index + patternData.count)
            if mutable[range] == patternData[patternData.startIndex..<patternData.endIndex] {
                mutable.replaceSubrange(range, with: replacementData)
            }
        }

        return mutable
    }
}
