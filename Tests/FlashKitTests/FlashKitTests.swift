import Foundation
import FlashKitHelperProtocol
import Testing
@testable import FlashKit

struct FlashKitTests {
    @Test
    func sanitizesFatVolumeLabels() {
        #expect(VolumeLabelFormatter.sanitizedFATLabel("win usb 11 installer") == "WIN_USB_11_")
        #expect(VolumeLabelFormatter.sanitizedFATLabel("!!!") == "USBMEDIA")
    }

    @Test
    func recommendsWindowsVersionVolumeLabels() {
        let windows11Profile = SourceImageProfile(
            sourceURL: URL(fileURLWithPath: "/tmp/Win11_24H2_English_x64.iso"),
            format: .iso,
            size: 1,
            detectedVolumeName: "CCCOMA_X64FRE_EN-US_DV9",
            hasEFI: true,
            hasBIOS: true,
            oversizedPaths: [],
            bootArtifactPaths: [],
            supportedMediaModes: [.windowsInstaller],
            notes: [],
            windows: WindowsImageProfile(
                installImageRelativePath: "sources/install.wim",
                installImageSize: 1,
                hasBootWIM: true,
                hasPantherUnattend: false,
                isWinPE: false,
                needsWindows7EFIFallback: false,
                requiresWIMSplit: false,
                requiresBIOSWinPEFixup: false,
                prefersPantherCustomization: true
            ),
            supportsDOSBoot: false,
            supportsLinuxBoot: false,
            supportsPersistence: false,
            persistenceFlavor: .none,
            secureBootValidationCandidate: true,
            downloadFamily: .windows
        )
        let windows10Profile = SourceImageProfile(
            sourceURL: URL(fileURLWithPath: "/tmp/Win10_22H2_English_x64.iso"),
            format: .iso,
            size: 1,
            detectedVolumeName: "CCCOMA_X64FRE_EN-US_DV9",
            hasEFI: true,
            hasBIOS: true,
            oversizedPaths: [],
            bootArtifactPaths: [],
            supportedMediaModes: [.windowsInstaller],
            notes: [],
            windows: windows11Profile.windows,
            supportsDOSBoot: false,
            supportsLinuxBoot: false,
            supportsPersistence: false,
            persistenceFlavor: .none,
            secureBootValidationCandidate: true,
            downloadFamily: .windows
        )

        #expect(windows11Profile.recommendedVolumeLabel == "WIN11")
        #expect(windows10Profile.recommendedVolumeLabel == "WIN10")
    }

    @Test
    func recommendsLinuxDistributionVolumeLabels() {
        let profile = SourceImageProfile(
            sourceURL: URL(fileURLWithPath: "/tmp/ubuntu-24.04-desktop-amd64.iso"),
            format: .iso,
            size: 1,
            detectedVolumeName: "Ubuntu 24.04 LTS",
            hasEFI: true,
            hasBIOS: true,
            oversizedPaths: [],
            bootArtifactPaths: [],
            supportedMediaModes: [.directImage],
            notes: [],
            windows: nil,
            supportsDOSBoot: false,
            supportsLinuxBoot: true,
            supportsPersistence: false,
            persistenceFlavor: .none,
            secureBootValidationCandidate: true,
            downloadFamily: nil,
            linuxDistribution: .ubuntu
        )

        #expect(profile.recommendedVolumeLabel == "UBUNTU")
    }

    @Test
    func recommendsFilenameDerivedLabelsForGenericImages() {
        let profile = SourceImageProfile(
            sourceURL: URL(fileURLWithPath: "/tmp/custom_router_recovery.img.xz"),
            format: .dd,
            size: 1,
            detectedVolumeName: nil,
            hasEFI: false,
            hasBIOS: false,
            oversizedPaths: [],
            bootArtifactPaths: [],
            supportedMediaModes: [.directImage],
            notes: [],
            windows: nil,
            supportsDOSBoot: false,
            supportsLinuxBoot: false,
            supportsPersistence: false,
            persistenceFlavor: .none,
            secureBootValidationCandidate: false,
            downloadFamily: nil
        )

        #expect(profile.recommendedVolumeLabel == "CUSTOM_ROUT")
    }

    @Test
    func partitioningUsesSelectedVolumeLabelForPayloadPartitions() {
        let directPlan = WritePlan(
            mediaMode: .windowsInstaller,
            payloadMode: .fat32SplitWim,
            partitionScheme: .mbr,
            targetSystem: .dual,
            primaryFilesystem: .fat32,
            partitionLayouts: [
                PartitionLayout(name: "WINDOWS", filesystem: .fat32, sizeMiB: nil, description: "Bootable installer payload")
            ],
            helperRequirements: [],
            postWriteFixups: [],
            verificationMode: .none,
            verificationSteps: [],
            warnings: [],
            summary: "",
            isBlocked: false,
            blockingReason: nil
        )
        let ntfsPlan = WritePlan(
            mediaMode: .windowsInstaller,
            payloadMode: .ntfsUefiNtfs,
            partitionScheme: .mbr,
            targetSystem: .dual,
            primaryFilesystem: .ntfs,
            partitionLayouts: [
                PartitionLayout(name: "UEFI_NTFS", filesystem: .fat32, sizeMiB: 1, description: "Boot bridge partition"),
                PartitionLayout(name: "WINDOWS", filesystem: .ntfs, sizeMiB: nil, description: "NTFS Windows installer payload"),
            ],
            helperRequirements: [],
            postWriteFixups: [],
            verificationMode: .none,
            verificationSteps: [],
            warnings: [],
            summary: "",
            isBlocked: false,
            blockingReason: nil
        )

        let directLayouts = PartitioningService.resolvedPartitionLayouts(for: directPlan, volumeLabel: "WIN11")
        let ntfsLayouts = PartitioningService.resolvedPartitionLayouts(for: ntfsPlan, volumeLabel: "Fedora Workstation")

        #expect(directLayouts[0].name == "WIN11")
        #expect(ntfsLayouts[0].name == "UEFI_NTFS")
        #expect(ntfsLayouts[1].name == "FEDORA_WORK")
    }

    @Test
    func stagedSplitInstallFilesDiscoverPreparedSwmParts() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("FlashKit-Test-\(UUID().uuidString)", isDirectory: true)
        let splitDirectory = root.appendingPathComponent("sources", isDirectory: true)
        try FileManager.default.createDirectory(at: splitDirectory, withIntermediateDirectories: true)

        let first = splitDirectory.appendingPathComponent("install.swm")
        let second = splitDirectory.appendingPathComponent("install2.swm")
        let unrelated = splitDirectory.appendingPathComponent("boot.wim")

        try Data("one".utf8).write(to: first)
        try Data("two".utf8).write(to: second)
        try Data("ignore".utf8).write(to: unrelated)
        defer { try? FileManager.default.removeItem(at: root) }

        let files = try WindowsInstallerService().stagedSplitInstallFiles(
            in: root,
            relativeInstallPath: "sources/install.wim"
        )

        #expect(files.map(\.lastPathComponent) == ["install.swm", "install2.swm"])
    }

    @Test
    func activityLogFormatterIncludesClassificationStrategyAndWarnings() {
        let sourceURL = URL(fileURLWithPath: "/tmp/proxmox-ve.iso")
        let classification = classificationResult(
            sourceURL: sourceURL,
            probe: ImageBinaryProbe.synthetic(
                sourceURL: sourceURL,
                declaredFormat: .iso,
                hasISO9660Marker: true,
                hasMBRSignature: true,
                isoHybridStyle: .hybridMBR
            ),
            paths: ["pve-installer", "boot/grub/grub.cfg"],
            bootArtifacts: ["efi/boot/bootx64.efi"],
            hasEFI: true,
            hasBIOS: true
        )
        let profile = classifiedProfile(
            sourceURL: sourceURL,
            format: .iso,
            classification: classification,
            hasEFI: true,
            hasBIOS: true
        )

        let lines = BackendActivityLogFormatter.classificationLines(for: profile)

        #expect(lines.contains(where: { $0.contains("[CLASSIFY]") && $0.contains("kind=hybrid-iso") }))
        #expect(lines.contains(where: { $0.contains("vendor=proxmox-ve") && $0.contains("strategy=preserve-hybrid-direct-write") }))
    }

    @Test
    func activityLogFormatterIncludesValidationFailureDetails() {
        let result = MediaValidationResult(
            passed: false,
            confidence: 0.42,
            depth: .full,
            checksPerformed: [
                MediaValidationCheck(
                    identifier: "vendor-pfsense-boot",
                    title: "pfSense boot artifacts",
                    status: .failed,
                    detail: "Missing the expected pfSense memstick boot artifacts."
                ),
            ],
            warnings: ["Mounted filesystems were limited during inspection."],
            profileNotes: ["pfSense variant: serial."],
            structurallyPlausibleButNotGuaranteedBootable: false,
            matchedProfile: .pfSense,
            profileVariant: "serial",
            failureReason: "Missing the expected pfSense memstick boot artifacts."
        )

        let lines = BackendActivityLogFormatter.validationLines(result)

        #expect(lines.contains(where: { $0.contains("[VALIDATE] passed=false") && $0.contains("vendor=pfsense") }))
        #expect(lines.contains(where: { $0.contains("checks=vendor-pfsense-boot:failed") }))
        #expect(lines.contains(where: { $0.contains("failure=Missing the expected pfSense memstick boot artifacts.") }))
        #expect(lines.contains(where: { $0.contains("notes=pfSense variant: serial.") }))
    }

    @Test
    func processRunnerCancelsLongRunningSubprocesses() async throws {
        let task = Task {
            try await ProcessRunner().run("/bin/sh", arguments: ["-c", "sleep 10"])
        }

        try await Task.sleep(for: .milliseconds(100))
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("Expected the subprocess to be cancelled.")
        } catch is CancellationError {
            #expect(Bool(true))
        }
    }

    @Test
    func recognizesBridgedCancellationErrors() {
        #expect(isCancellationLikeError(CancellationError()))
        #expect(isCancellationLikeError(NSError(domain: "Swift.CancellationError", code: 1)))
        #expect(!isCancellationLikeError(NSError(domain: NSCocoaErrorDomain, code: 4)))
    }

    @Test
    func privilegedCommandServiceFallsBackToPasswordPromptPathForSubprocessesWhenHelperIsMissing() async throws {
        let fallback = RecordingPrivilegedClient()
        let service = PrivilegedCommandService(
            helperClient: FailingPrivilegedClient(error: .helperUnavailable),
            fallbackClient: fallback
        )

        let result = try await service.run(
            "/usr/bin/id",
            arguments: ["-u"],
            phase: "Checking identity",
            message: "Running a privileged test command."
        )

        let recorded = await fallback.snapshotSubprocessRequests()

        #expect(recorded.count == 1)
        #expect(recorded[0].executable == "/usr/bin/id")
        #expect(recorded[0].arguments == ["-u"])
        #expect(result.helperPID == 700)
    }

    @Test
    func privilegedCommandServiceFallsBackToPasswordPromptPathForRawWritesWhenHelperIsMissing() async throws {
        let sourceURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("img")
        try Data(repeating: 0xCD, count: 4096).write(to: sourceURL)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let fallback = RecordingPrivilegedClient()
        let service = PrivilegedCommandService(
            helperClient: FailingPrivilegedClient(error: .helperUnavailable),
            fallbackClient: fallback
        )

        _ = try await service.writeRaw(
            input: .file(sourceURL),
            to: "/dev/rdisk8",
            expectedBytes: 4096,
            phase: "Restoring image",
            message: "Writing the raw image to the raw device.",
            targetExpectation: nil
        )

        let recorded = await fallback.snapshotRawWriteRequests()

        #expect(recorded.count == 1)
        #expect(recorded[0].sourceFilePath == sourceURL.path())
        #expect(recorded[0].destinationDeviceNode == "/dev/rdisk8")
        #expect(recorded[0].expectedBytes == 4096)
    }

    @Test
    func privilegedHelperStatusServiceExplainsPasswordPromptFallbackWhenHelperIsMissing() async {
        let service = PrivilegedHelperStatusService(
            helperClient: FailingPrivilegedClient(error: .helperUnavailable)
        )

        let availability = await service.availability()

        #expect(!availability.isAvailable)
        #expect(availability.bannerMessage?.contains("macOS administrator password prompt") == true)
    }

    @Test
    func rawDeviceWriterRoutesPlainImagesThroughPrivilegedHelper() async throws {
        let sourceURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("img")
        try Data(repeating: 0xAB, count: 4096).write(to: sourceURL)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let client = RecordingPrivilegedClient()
        let service = RawDeviceWriterService(
            privileged: PrivilegedCommandService(client: client)
        )
        let expectation = PrivilegedTargetExpectation(
            expectedDeviceNode: "/dev/disk9",
            expectedWholeDisk: true,
            expectedSizeBytes: 4096,
            requireWritable: true,
            requireRemovable: true,
            allowUnsafeTargetsWithExpertOverride: true,
            expertOverrideEnabled: false,
            forceUnmountWholeDisk: true
        )

        _ = try await service.write(
            input: .file(sourceURL),
            to: "/dev/rdisk9",
            expectedBytes: 4096,
            targetExpectation: expectation,
            phase: "Restoring image",
            message: "Writing the raw image to the raw device."
        )

        let recorded = await client.snapshotRawWriteRequests()
        #expect(recorded.count == 1)
        #expect(recorded[0].sourceFilePath == sourceURL.path())
        #expect(recorded[0].streamExecutablePath == nil)
        #expect(recorded[0].destinationDeviceNode == "/dev/rdisk9")
        #expect(recorded[0].expectedBytes == 4096)
        #expect(recorded[0].targetExpectation?.expectedDeviceNode == "/dev/disk9")
    }

    @Test
    func rawDeviceWriterRoutesCompressedImagesThroughStreamingHelper() async throws {
        let client = RecordingPrivilegedClient()
        let service = RawDeviceWriterService(
            privileged: PrivilegedCommandService(client: client)
        )
        let streamed = StreamedDecompressionCommand(
            compression: .xz,
            executable: "/tmp/xz",
            arguments: ["-dc", "/tmp/router.img.xz"],
            logicalSizeHint: 9_999
        )

        _ = try await service.write(
            input: .streamed(streamed),
            to: "/dev/rdisk5",
            expectedBytes: nil,
            targetExpectation: nil,
            phase: "Restoring image",
            message: "Streaming the xz-compressed raw image into the raw device."
        )

        let recorded = await client.snapshotRawWriteRequests()
        #expect(recorded.count == 1)
        #expect(recorded[0].sourceFilePath == nil)
        #expect(recorded[0].streamExecutablePath == "/tmp/xz")
        #expect(recorded[0].streamArguments == ["-dc", "/tmp/router.img.xz"])
        #expect(recorded[0].expectedBytes == 9_999)
    }

    @Test
    func countedFileCopyServiceReportsIncrementalByteProgress() async throws {
        let sourceRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let destinationRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: sourceRoot)
            try? FileManager.default.removeItem(at: destinationRoot)
        }

        let sourceFile = sourceRoot.appending(path: "large.bin")
        try Data(repeating: 0x5A, count: 2_500_000).write(to: sourceFile)

        let service = CountedFileCopyService()
        let manifest = try service.manifest(from: sourceRoot, skippingRelativePaths: [])
        let recorder = SnapshotRecorder()

        try await service.copyManifest(manifest, to: destinationRoot) { completedBytes, _, _ in
            await recorder.append(completedBytes)
        }

        let snapshots = await recorder.values()

        #expect(snapshots.count > 1)
        #expect(snapshots.last == 2_500_000)
    }

    @Test
    func activityLogFormatterIncludesWorkerAndProgressDiagnostics() {
        let telemetry = BackendWorkerRuntimeTelemetry(
            helperProtocolVersion: 1,
            helperPID: 901,
            workerPID: 902,
            workerCommand: ["/usr/local/bin/wimlib-imagex", "split", "install.wim"]
        )

        let workerLines = BackendActivityLogFormatter.workerLines(telemetry, mode: "local-subprocess")
        let progressLines = BackendActivityLogFormatter.progressLines(
            phase: "Copying files",
            completedBytes: 1_073_741_824,
            totalBytes: 2_147_483_648,
            rateBytesPerSecond: 268_435_456
        )

        #expect(workerLines.contains(where: { $0.contains("[WORKER] mode=local-subprocess") && $0.contains("child-pid=902") }))
        #expect(workerLines.contains(where: { $0.contains("command=/usr/local/bin/wimlib-imagex split install.wim") }))
        #expect(progressLines.contains(where: { $0.contains("[PROGRESS] phase=Copying files") && $0.contains("percent=50%") }))
    }

    @Test
    func plansFat32SplitForLargeWindowsInstallImage() {
        let profile = windowsInstallerProfile(
            oversizedPaths: ["sources/install.wim"],
            requiresWIMSplit: true,
            installImageSize: SourceImageProfile.fat32MaximumFileSize + 1
        )
        let plan = WritePlanBuilder().buildPlan(
            for: profile,
            targetDisk: nil,
            toolchain: toolchain(available: [.wimlibImagex])
        )

        #expect(plan.mediaMode == .windowsInstaller)
        #expect(plan.primaryFilesystem == .fat32)
        #expect(plan.payloadMode == .fat32SplitWim)
        #expect(plan.usesUEFINTFSPath == false)
        #expect(plan.helperRequirements.contains(where: { $0.tool == .wimlibImagex }))
        #expect(plan.isBlocked == false)
    }

    @Test
    func plansFat32ExtractWhenWindowsInstallImageFitsFat32() {
        let profile = windowsInstallerProfile(
            oversizedPaths: [],
            requiresWIMSplit: false,
            installImageSize: SourceImageProfile.fat32MaximumFileSize - 1
        )
        let plan = WritePlanBuilder().buildPlan(
            for: profile,
            targetDisk: nil,
            toolchain: toolchain(available: [.wimlibImagex])
        )

        #expect(plan.mediaMode == .windowsInstaller)
        #expect(plan.primaryFilesystem == .fat32)
        #expect(plan.payloadMode == .fat32Extract)
        #expect(plan.usesUEFINTFSPath == false)
        #expect(!plan.helperRequirements.contains(where: { $0.tool == .wimlibImagex }))
        #expect(plan.isBlocked == false)
    }

    @Test
    func plansUEFINTFSPathWhenFat32WouldMissThePayload() {
        let profile = windowsInstallerProfile(
            oversizedPaths: ["sources/install.wim", "sources/install-resources.cab"],
            requiresWIMSplit: true
        )
        let plan = WritePlanBuilder().buildPlan(
            for: profile,
            targetDisk: nil,
            toolchain: toolchain(available: [.uefiNTFSImage, .mkntfs, .ntfsPopulateHelper, .ntfsfix])
        )

        #expect(plan.mediaMode == .windowsInstaller)
        #expect(plan.primaryFilesystem == .ntfs)
        #expect(plan.payloadMode == .ntfsUefiNtfs)
        #expect(plan.usesUEFINTFSPath)
        #expect(plan.helperRequirements.contains(where: { $0.tool == .uefiNTFSImage }))
        #expect(plan.helperRequirements.contains(where: { $0.tool == .mkntfs }))
        #expect(plan.summary.contains("NTFS"))
    }

    @Test
    func plansGenericOversizedEfiForNonWindowsImages() {
        let profile = SourceImageProfile(
            sourceURL: URL(fileURLWithPath: "/tmp/linux.iso"),
            format: .iso,
            size: 6_000_000_000,
            detectedVolumeName: "LINUX_LIVE",
            hasEFI: true,
            hasBIOS: false,
            oversizedPaths: ["casper/filesystem.squashfs"],
            bootArtifactPaths: ["efi/boot/bootx64.efi"],
            supportedMediaModes: [.directImage],
            notes: [],
            windows: nil,
            supportsDOSBoot: false,
            supportsLinuxBoot: true,
            supportsPersistence: false,
            persistenceFlavor: .none,
            secureBootValidationCandidate: true,
            downloadFamily: nil
        )
        let plan = WritePlanBuilder().buildPlan(
            for: profile,
            targetDisk: nil,
            toolchain: toolchain(available: [.uefiNTFSImage])
        )

        #expect(plan.mediaMode == MediaMode.directImage)
        #expect(plan.payloadMode == WindowsInstallerPayloadMode.genericOversizedEfi)
        #expect(plan.primaryFilesystem == FilesystemType.exfat)
        #expect(plan.helperRequirements.contains(where: { $0.tool == HelperTool.uefiNTFSImage }))
    }

    @Test
    func plansBundledFreeDOSAsBootableFat32Media() {
        let profile = SourceImageProfile(
            sourceURL: URL(fileURLWithPath: "/tmp/FreeDOS"),
            format: .unknown,
            size: 42_000_000,
            detectedVolumeName: "FreeDOS",
            hasEFI: false,
            hasBIOS: true,
            oversizedPaths: [],
            bootArtifactPaths: [],
            supportedMediaModes: [.directImage],
            notes: [],
            windows: nil,
            supportsDOSBoot: true,
            supportsLinuxBoot: false,
            supportsPersistence: false,
            persistenceFlavor: .none,
            secureBootValidationCandidate: false,
            downloadFamily: nil
        )

        let plan = WritePlanBuilder().buildPlan(
            for: profile,
            targetDisk: nil,
            toolchain: toolchain(available: [.freedosBootHelper])
        )

        #expect(plan.payloadMode == .freeDOS)
        #expect(plan.primaryFilesystem == .fat32)
        #expect(plan.postWriteFixups.contains(.freeDOSBootSector))
    }

    @Test
    func plansLinuxPersistenceWhenEnabledForRecognizedMedia() {
        let profile = SourceImageProfile(
            sourceURL: URL(fileURLWithPath: "/tmp/ubuntu.iso"),
            format: .iso,
            size: 3_000_000_000,
            detectedVolumeName: "Ubuntu",
            hasEFI: true,
            hasBIOS: true,
            oversizedPaths: [],
            bootArtifactPaths: ["efi/boot/bootx64.efi"],
            supportedMediaModes: [.directImage],
            notes: [],
            windows: nil,
            supportsDOSBoot: false,
            supportsLinuxBoot: true,
            supportsPersistence: true,
            persistenceFlavor: .casper,
            secureBootValidationCandidate: true,
            downloadFamily: nil
        )
        var options = WriteOptions()
        options.enableLinuxPersistence = true
        options.linuxPersistenceSizeMiB = 8_192

        let plan = WritePlanBuilder().buildPlan(
            for: profile,
            targetDisk: nil,
            toolchain: toolchain(available: [.mke2fs]),
            options: options
        )

        #expect(plan.payloadMode == .linuxPersistenceCasper)
        #expect(plan.partitionLayouts.count == 2)
        #expect(plan.partitionLayouts.last?.filesystem == .ext4)
    }

    @Test
    func plansGenericLinuxIsoAsExtractedBootMediaWhenPersistenceIsOff() {
        let profile = SourceImageProfile(
            sourceURL: URL(fileURLWithPath: "/tmp/fedora.iso"),
            format: .iso,
            size: 2_500_000_000,
            detectedVolumeName: "Fedora-Workstation-Live",
            hasEFI: true,
            hasBIOS: true,
            oversizedPaths: [],
            bootArtifactPaths: ["efi/boot/bootx64.efi", "boot/grub/grub.cfg", "isolinux/isolinux.cfg"],
            supportedMediaModes: [.directImage],
            notes: [],
            windows: nil,
            supportsDOSBoot: false,
            supportsLinuxBoot: true,
            supportsPersistence: false,
            persistenceFlavor: .none,
            secureBootValidationCandidate: true,
            downloadFamily: nil
        )

        let plan = WritePlanBuilder().buildPlan(
            for: profile,
            targetDisk: nil,
            toolchain: toolchain()
        )

        #expect(plan.payloadMode == .fat32Extract)
        #expect(plan.primaryFilesystem == .fat32)
        #expect(plan.summary.contains("Linux image"))
        #expect(plan.verificationMode == .bootArtifacts)
    }

    @Test
    func detectsHybridMBRIsoHeader() throws {
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("iso")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        var bytes = Data(repeating: 0, count: 1_024)
        bytes[446 + 4] = 0x17
        bytes[446 + 12] = 0x20
        bytes[510] = 0x55
        bytes[511] = 0xAA
        try bytes.write(to: tempURL)

        let style = try ISOHybridDetector().detectStyle(for: tempURL)
        #expect(style == .hybridMBR)
    }

    @Test
    func detectsNonHybridIsoHeader() throws {
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("iso")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        try Data(repeating: 0, count: 1_024).write(to: tempURL)

        let style = try ISOHybridDetector().detectStyle(for: tempURL)
        #expect(style == .nonHybrid)
    }

    @Test
    func classifiesPlainIsoFromIsoMarkers() throws {
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("iso")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        try makeOpticalImageFixture(at: tempURL, hybridMBR: false)

        let probe = try ImageBinaryProbeService().probeFile(at: tempURL, declaredFormat: .iso)
        #expect(probe.imageKind == .plainISO)
        #expect(probe.hasISO9660Marker)
    }

    @Test
    func classifiesHybridIsoFromIsoMarkersAndPartitionTable() throws {
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("iso")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        try makeOpticalImageFixture(at: tempURL, hybridMBR: true)

        let probe = try ImageBinaryProbeService().probeFile(at: tempURL, declaredFormat: .iso)
        #expect(probe.imageKind == .hybridISO)
        #expect(probe.isoHybridStyle == .hybridMBR)
    }

    @Test
    func plansHybridLinuxIsoForDirectWriteWhenNoRebuildIsNeeded() {
        let profile = SourceImageProfile(
            sourceURL: URL(fileURLWithPath: "/tmp/ubuntu.iso"),
            format: .iso,
            size: 2_200_000_000,
            detectedVolumeName: "Ubuntu 24.04 LTS",
            hasEFI: true,
            hasBIOS: true,
            oversizedPaths: [],
            bootArtifactPaths: ["efi/boot/bootx64.efi", "isolinux/isolinux.bin"],
            supportedMediaModes: [.directImage],
            notes: [],
            windows: nil,
            supportsDOSBoot: false,
            supportsLinuxBoot: true,
            supportsPersistence: false,
            persistenceFlavor: .none,
            secureBootValidationCandidate: true,
            downloadFamily: nil,
            isoHybridStyle: .hybridMBR,
            linuxDistribution: .ubuntu,
            linuxBootFixes: []
        )

        let plan = WritePlanBuilder().buildPlan(for: profile, targetDisk: nil, toolchain: toolchain())
        #expect(plan.payloadMode == .directRaw)
        #expect(plan.summary.contains("hybrid Linux ISO"))
    }

    @Test
    func plansNonHybridLinuxIsoForExtractionRebuild() {
        let profile = SourceImageProfile(
            sourceURL: URL(fileURLWithPath: "/tmp/linux.iso"),
            format: .iso,
            size: 1_900_000_000,
            detectedVolumeName: "Linux-Live",
            hasEFI: true,
            hasBIOS: false,
            oversizedPaths: [],
            bootArtifactPaths: ["boot/grub/grub.cfg"],
            supportedMediaModes: [.directImage],
            notes: [],
            windows: nil,
            supportsDOSBoot: false,
            supportsLinuxBoot: true,
            supportsPersistence: false,
            persistenceFlavor: .none,
            secureBootValidationCandidate: true,
            downloadFamily: nil,
            isoHybridStyle: .nonHybrid,
            linuxDistribution: .generic,
            linuxBootFixes: []
        )

        let plan = WritePlanBuilder().buildPlan(for: profile, targetDisk: nil, toolchain: toolchain())
        #expect(plan.payloadMode == .fat32Extract)
        #expect(plan.summary.contains("Extract and rebuild"))
    }

    @Test
    func plansHybridLinuxIsoWithFixupsForExtractionWhenPayloadFits() {
        let profile = SourceImageProfile(
            sourceURL: URL(fileURLWithPath: "/tmp/weird-linux.iso"),
            format: .iso,
            size: 1_400_000_000,
            detectedVolumeName: "Strange Linux",
            hasEFI: true,
            hasBIOS: true,
            oversizedPaths: [],
            bootArtifactPaths: ["efi/vendor/grubx64.efi", "grub/grub.cfg"],
            supportedMediaModes: [.directImage],
            notes: [],
            windows: nil,
            supportsDOSBoot: false,
            supportsLinuxBoot: true,
            supportsPersistence: false,
            persistenceFlavor: .none,
            secureBootValidationCandidate: true,
            downloadFamily: nil,
            isoHybridStyle: .hybridMBR,
            linuxDistribution: .generic,
            linuxBootFixes: [.normalizeEFIBootFiles]
        )

        let plan = WritePlanBuilder().buildPlan(for: profile, targetDisk: nil, toolchain: toolchain())
        #expect(plan.payloadMode == .fat32Extract)
    }

    @Test
    func forcesGPTForHybridGptLinuxRebuildsWhenFixupsAreNeeded() {
        let profile = SourceImageProfile(
            sourceURL: URL(fileURLWithPath: "/tmp/efi-linux.iso"),
            format: .iso,
            size: 1_700_000_000,
            detectedVolumeName: "EFI Linux",
            hasEFI: true,
            hasBIOS: true,
            oversizedPaths: [],
            bootArtifactPaths: ["efi/vendor/grubx64.efi", "grub/grub.cfg"],
            supportedMediaModes: [.directImage],
            notes: [],
            windows: nil,
            supportsDOSBoot: false,
            supportsLinuxBoot: true,
            supportsPersistence: false,
            persistenceFlavor: .none,
            secureBootValidationCandidate: true,
            downloadFamily: nil,
            isoHybridStyle: .hybridGPT,
            linuxDistribution: .generic,
            linuxBootFixes: [.normalizeEFIBootFiles]
        )

        let plan = WritePlanBuilder().buildPlan(for: profile, targetDisk: nil, toolchain: toolchain())
        #expect(plan.payloadMode == .fat32Extract)
        #expect(plan.partitionScheme == .gpt)
        #expect(plan.postWriteFixups.contains(.repairEFISystemPartition))
    }

    @Test
    func detectsKaliPersistenceAndLinuxFixupsFromDirectory() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("live"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("grub"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("EFI/kali"), withIntermediateDirectories: true)
        try Data("menuentry 'Kali' { linux /live/vmlinuz boot=live components }\n".utf8)
            .write(to: root.appendingPathComponent("grub/grub.cfg"))
        try Data(repeating: 1, count: 16).write(to: root.appendingPathComponent("live/filesystem.squashfs"))
        try Data(repeating: 2, count: 16).write(to: root.appendingPathComponent("EFI/kali/grubx64.efi"))

        let profile = try await ImageInspectionService().inspectImage(at: root)

        #expect(profile.supportsLinuxBoot)
        #expect(profile.supportsPersistence)
        #expect(profile.persistenceFlavor == .debian)
        #expect(profile.linuxDistribution == .kali)
        #expect(profile.linuxBootFixes.contains(.normalizeEFIBootFiles))
        #expect(profile.linuxBootFixes.contains(.mirrorGRUBConfig))
    }

    @Test
    func detectsProxmoxApplianceProfileFromDirectory() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("proxmox-ve-installer", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("boot/grub"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("EFI/BOOT"), withIntermediateDirectories: true)
        try Data("menuentry 'Proxmox' { linux /boot/linux26 }\n".utf8)
            .write(to: root.appendingPathComponent("boot/grub/grub.cfg"))
        try Data(repeating: 3, count: 32).write(to: root.appendingPathComponent("EFI/BOOT/BOOTX64.EFI"))

        let profile = try await ImageInspectionService().inspectImage(at: root)

        #expect(profile.applianceProfile == .proxmoxInstaller)
        #expect(profile.headline == "Detected: Proxmox installer")
    }

    @Test
    func detectsTrueNASApplianceProfileFromDirectory() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("TrueNAS-SCALE", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("boot/defaults"), withIntermediateDirectories: true)
        try Data(repeating: 4, count: 32).write(to: root.appendingPathComponent("boot/loader.efi"))
        try Data("comconsole_speed=\"115200\"\n".utf8)
            .write(to: root.appendingPathComponent("boot/defaults/loader.conf"))

        let profile = try await ImageInspectionService().inspectImage(at: root)

        #expect(profile.applianceProfile == .trueNASInstaller)
        #expect(profile.hasEFI)
        #expect(profile.requiresEFIRepairOnExtractedMedia)
    }

    @Test
    func doesNotMisclassifyStandardWindowsInstallerAsWinPE() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(at: root.appendingPathComponent("sources"), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 32).write(to: root.appendingPathComponent("sources/boot.wim"))
        try Data(repeating: 2, count: 32).write(to: root.appendingPathComponent("sources/install.wim"))
        try Data(repeating: 3, count: 32).write(to: root.appendingPathComponent("bootmgr"))

        let profile = try await ImageInspectionService().inspectImage(at: root)

        #expect(profile.windows?.hasBootWIM == true)
        #expect(profile.windows?.isWinPE == false)
        #expect(profile.windows?.requiresBIOSWinPEFixup == false)
    }

    @Test
    func detectsOpenWrtApplianceProfileFromFilename() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let imageURL = directory.appendingPathComponent("openwrt-24.10-x86-64-generic-ext4-combined.img")
        try Data(repeating: 0x11, count: 2_048).write(to: imageURL)

        let profile = try await ImageInspectionService().inspectImage(at: imageURL)

        #expect(profile.applianceProfile == .openWrtImage)
        #expect(profile.summaryLine.contains("raw-write"))
    }

    @Test
    func classifiesOpenWrtCombinedRawImagesAsSafeRawWrites() {
        let sourceURL = URL(fileURLWithPath: "/tmp/openwrt-24.10-x86-64-generic-ext4-combined-efi.img.gz")
        let probe = ImageBinaryProbe.synthetic(
            sourceURL: sourceURL,
            fileSize: 1_000_000_000,
            declaredFormat: .dd,
            compression: .gzip,
            hasGzipMagic: true
        )

        let result = classificationResult(sourceURL: sourceURL, probe: probe)

        #expect(result.imageKind == .compressedRawDiskImage)
        #expect(result.matchedVendorProfile == .openWrt)
        #expect(result.recommendedWriteStrategy == .rawDiskWrite)
        #expect(result.safetyPolicy == .safeToProceed)
    }

    @Test
    func rejectsOpenWrtDeviceSpecificArtifactsForGenericUsbMedia() {
        let sourceURL = URL(fileURLWithPath: "/tmp/openwrt-ath79-generic-sysupgrade.bin")
        let probe = ImageBinaryProbe.synthetic(
            sourceURL: sourceURL,
            fileSize: 48_000_000,
            declaredFormat: .unknown
        )

        let result = classificationResult(sourceURL: sourceURL, probe: probe)

        #expect(result.matchedVendorProfile == .openWrt)
        #expect(result.recommendedWriteStrategy == .rejectLikelyWrongImage)
        #expect(result.safetyPolicy == .rejectLikelyWrongImage)
        #expect(result.warnings.contains(where: { $0.contains("device-specific OpenWrt firmware artifact") }))
    }

    @Test
    func warnsOnOpenWrtRawImagesWhenTheVariantIsNotClearlyCombined() {
        let sourceURL = URL(fileURLWithPath: "/tmp/openwrt-generic-custom.img.gz")
        let probe = ImageBinaryProbe.synthetic(
            sourceURL: sourceURL,
            fileSize: 600_000_000,
            declaredFormat: .dd,
            compression: .gzip,
            hasGzipMagic: true
        )

        let result = classificationResult(sourceURL: sourceURL, probe: probe)

        #expect(result.matchedVendorProfile == .openWrt)
        #expect(result.recommendedWriteStrategy == .rawDiskWrite)
        #expect(result.safetyPolicy == .proceedWithWarning)
        #expect(result.warnings.contains(where: { $0.contains("could not confirm a clearly generic x86-style combined image") }))
    }

    @Test
    func distinguishesOPNsenseSerialMemstickImages() {
        let sourceURL = URL(fileURLWithPath: "/tmp/OPNsense-25.1-serial-amd64-memstick.img.gz")
        let probe = ImageBinaryProbe.synthetic(
            sourceURL: sourceURL,
            fileSize: 900_000_000,
            declaredFormat: .dd,
            compression: .gzip,
            hasGzipMagic: true
        )

        let result = classificationResult(sourceURL: sourceURL, probe: probe)

        #expect(result.matchedVendorProfile == .opnSense)
        #expect(result.matchedProfile?.variant == "serial")
        #expect(result.recommendedWriteStrategy == .memstickRawWrite)
    }

    @Test
    func distinguishesPfSenseVgaMemstickImages() {
        let sourceURL = URL(fileURLWithPath: "/tmp/pfSense-CE-memstick-amd64-vga.img.gz")
        let probe = ImageBinaryProbe.synthetic(
            sourceURL: sourceURL,
            fileSize: 900_000_000,
            declaredFormat: .dd,
            compression: .gzip,
            hasGzipMagic: true
        )

        let result = classificationResult(sourceURL: sourceURL, probe: probe)

        #expect(result.matchedVendorProfile == .pfSense)
        #expect(result.matchedProfile?.variant == "vga")
        #expect(result.recommendedWriteStrategy == .memstickRawWrite)
    }

    @Test
    func ambiguousVendorSignalsRequireExpertOverride() {
        let sourceURL = URL(fileURLWithPath: "/tmp/opnsense-pfsense-memstick-serial-vga.img.gz")
        let probe = ImageBinaryProbe.synthetic(
            sourceURL: sourceURL,
            fileSize: 900_000_000,
            declaredFormat: .dd,
            compression: .gzip,
            hasGzipMagic: true
        )

        let result = classificationResult(sourceURL: sourceURL, probe: probe)

        #expect(result.matchedProfile == nil)
        #expect(result.safetyPolicy == .requireExpertOverride)
        #expect(result.requiresExpertOverride)
        #expect(result.warnings.contains(where: { $0.contains("Multiple vendor profiles matched") }))
    }

    @Test
    func inspectImageCarriesTrueNASClassificationMetadata() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("truenas-backend-profile", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("boot/defaults"), withIntermediateDirectories: true)
        try Data(repeating: 7, count: 32).write(to: root.appendingPathComponent("boot/loader.efi"))
        try Data("console=\"comconsole\"\n".utf8)
            .write(to: root.appendingPathComponent("boot/defaults/loader.conf"))

        let profile = try await ImageInspectionService().inspectImage(at: root)

        #expect(profile.classification?.matchedVendorProfile == .trueNAS)
        #expect(profile.classification?.recommendedWriteStrategy == .extractAndRebuild)
    }

    @Test
    func plansOpenWrtApplianceForRawWrite() {
        let profile = SourceImageProfile(
            sourceURL: URL(fileURLWithPath: "/tmp/openwrt.img"),
            format: .dd,
            size: 300_000_000,
            detectedVolumeName: nil,
            hasEFI: false,
            hasBIOS: false,
            oversizedPaths: [],
            bootArtifactPaths: [],
            supportedMediaModes: [.directImage, .driveRestore],
            notes: [],
            windows: nil,
            supportsDOSBoot: false,
            supportsLinuxBoot: false,
            supportsPersistence: false,
            persistenceFlavor: .none,
            secureBootValidationCandidate: false,
            downloadFamily: nil,
            applianceProfile: .openWrtImage
        )

        let plan = WritePlanBuilder().buildPlan(for: profile, targetDisk: nil, toolchain: toolchain())
        #expect(plan.payloadMode == .directRaw)
        #expect(plan.summary.contains("OpenWrt"))
        #expect(plan.verificationMode == .rawByteCompare)
    }

    @Test
    func plansTrueNASApplianceForGptFat32RepairWhenNotRaw() {
        let profile = SourceImageProfile(
            sourceURL: URL(fileURLWithPath: "/tmp/truenas.iso"),
            format: .iso,
            size: 1_100_000_000,
            detectedVolumeName: "TrueNAS SCALE",
            hasEFI: true,
            hasBIOS: false,
            oversizedPaths: [],
            bootArtifactPaths: ["boot/loader.efi", "boot/defaults/loader.conf"],
            supportedMediaModes: [.directImage],
            notes: [],
            windows: nil,
            supportsDOSBoot: false,
            supportsLinuxBoot: false,
            supportsPersistence: false,
            persistenceFlavor: .none,
            secureBootValidationCandidate: true,
            downloadFamily: nil,
            isoHybridStyle: .nonHybrid,
            linuxDistribution: .none,
            linuxBootFixes: [],
            applianceProfile: .trueNASInstaller
        )

        let plan = WritePlanBuilder().buildPlan(for: profile, targetDisk: nil, toolchain: toolchain())
        #expect(plan.payloadMode == .fat32Extract)
        #expect(plan.primaryFilesystem == .fat32)
        #expect(plan.partitionScheme == .gpt)
        #expect(plan.postWriteFixups.contains(.repairEFISystemPartition))
    }

    @Test
    func plansProxmoxApplianceForExtractedFat32WhenHybridLayoutIsUnavailable() {
        let profile = SourceImageProfile(
            sourceURL: URL(fileURLWithPath: "/tmp/proxmox.iso"),
            format: .iso,
            size: 1_300_000_000,
            detectedVolumeName: "Proxmox VE",
            hasEFI: true,
            hasBIOS: false,
            oversizedPaths: [],
            bootArtifactPaths: ["efi/proxmox/grubx64.efi", "boot/grub/grub.cfg"],
            supportedMediaModes: [.directImage],
            notes: [],
            windows: nil,
            supportsDOSBoot: false,
            supportsLinuxBoot: true,
            supportsPersistence: false,
            persistenceFlavor: .none,
            secureBootValidationCandidate: true,
            downloadFamily: nil,
            isoHybridStyle: .nonHybrid,
            linuxDistribution: .generic,
            linuxBootFixes: [.normalizeEFIBootFiles],
            applianceProfile: .proxmoxInstaller
        )

        let plan = WritePlanBuilder().buildPlan(for: profile, targetDisk: nil, toolchain: toolchain())
        #expect(plan.payloadMode == .fat32Extract)
        #expect(plan.primaryFilesystem == .fat32)
        #expect(plan.partitionScheme == .gpt)
        #expect(plan.postWriteFixups.contains(.repairEFISystemPartition))
    }

    @Test
    func plainRawImagesAreRecognizedAsDirectImages() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let rawURL = directory.appendingPathComponent("disk.raw")
        try Data(repeating: 0xAB, count: 4_096).write(to: rawURL)

        let profile = try await ImageInspectionService().inspectImage(at: rawURL)

        #expect(profile.format == .dd)
        #expect(profile.supportedMediaModes == [.directImage, .driveRestore])
    }

    @Test
    func gzipCompressedRawImagesAreRecognizedAsDirectImages() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let rawURL = directory.appendingPathComponent("disk.img")
        let gzipURL = directory.appendingPathComponent("disk.img.gz")
        try Data(repeating: 0xCD, count: 8_192).write(to: rawURL)
        _ = try await ProcessRunner().run(
            "/bin/sh",
            arguments: ["-c", "exec /usr/bin/gzip -c \"$1\" > \"$2\"", "sh", rawURL.path(), gzipURL.path()]
        )

        let profile = try await ImageInspectionService().inspectImage(at: gzipURL)

        #expect(profile.format == .dd)
        #expect(profile.supportedMediaModes == [.directImage, .driveRestore])
        #expect(profile.notes.contains(where: { $0.contains("streamed directly into the target device") }))
    }

    @Test
    func xzCompressedRawImagesRequireXZHelperForPlanning() {
        let profile = SourceImageProfile(
            sourceURL: URL(fileURLWithPath: "/tmp/linux.img.xz"),
            format: .dd,
            size: 3_000_000_000,
            detectedVolumeName: nil,
            hasEFI: false,
            hasBIOS: false,
            oversizedPaths: [],
            bootArtifactPaths: [],
            supportedMediaModes: [.directImage, .driveRestore],
            notes: [],
            windows: nil,
            supportsDOSBoot: false,
            supportsLinuxBoot: false,
            supportsPersistence: false,
            persistenceFlavor: .none,
            secureBootValidationCandidate: false,
            downloadFamily: nil
        )

        let blockedPlan = WritePlanBuilder().buildPlan(
            for: profile,
            targetDisk: nil,
            toolchain: toolchain()
        )
        #expect(blockedPlan.isBlocked)
        #expect(blockedPlan.blockingReason?.contains("XZ-compressed") == true)

        let readyPlan = WritePlanBuilder().buildPlan(
            for: profile,
            targetDisk: nil,
            toolchain: toolchain(available: [.xz])
        )
        #expect(readyPlan.isBlocked == false)
        #expect(readyPlan.helperRequirements.contains(where: { $0.tool == .xz }))
    }

    @Test
    func unsupportedCompressedFormatsAreRejected() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let archiveURL = directory.appendingPathComponent("archive.iso.gz")
        try Data(repeating: 0xEE, count: 128).write(to: archiveURL)

        await #expect(throws: RawDiskImageServiceError.self) {
            _ = try await ImageInspectionService().inspectImage(at: archiveURL)
        }
    }

    @Test
    func bundledThirdPartyHelpersWinOverSystemCopies() async throws {
        let resourceDirectory = try makeResourceDirectory()
        defer { try? FileManager.default.removeItem(at: resourceDirectory.deletingLastPathComponent()) }
        let bundledMKNTFS = resourceDirectory.appending(path: "Helpers").appending(path: "mkntfs")
        try makeExecutable(at: bundledMKNTFS, body: "#!/bin/sh\necho bundled mkntfs\n")

        let service = BundledToolchainService(resourceDirectoriesOverride: [resourceDirectory])
        let status = await service.detectToolchain()
        let availability = status.availability(for: .mkntfs)

        #expect(availability.source == .bundled)
        #expect(availability.validationState == .ready)
        #expect(availability.path == bundledMKNTFS.path())
    }

    @Test
    func missingBundledThirdPartyHelpersDoNotFallBackToExternalInstalls() async throws {
        let resourceDirectory = try makeResourceDirectory()
        defer { try? FileManager.default.removeItem(at: resourceDirectory.deletingLastPathComponent()) }

        let service = BundledToolchainService(resourceDirectoriesOverride: [resourceDirectory])
        let status = await service.detectToolchain()
        let availability = status.availability(for: .mkntfs)

        #expect(availability.source == .missing)
        #expect(availability.validationState == .missing)
        #expect(availability.path == nil)
    }

    @Test
    func brokenBundledHelperMarksFeatureUnavailable() async throws {
        let resourceDirectory = try makeResourceDirectory()
        defer { try? FileManager.default.removeItem(at: resourceDirectory.deletingLastPathComponent()) }
        let brokenQEMU = resourceDirectory.appending(path: "Helpers").appending(path: "qemu-img")
        try makeExecutable(at: brokenQEMU, body: "#!/bin/sh\nexit 1\n")

        let service = BundledToolchainService(resourceDirectoriesOverride: [resourceDirectory])
        let status = await service.detectToolchain()
        let availability = status.availability(for: .qemuImg)

        #expect(availability.source == .bundled)
        #expect(availability.validationState == .broken)
        #expect(status.readiness == .degraded)
        #expect(status.summaryLine == "Bundle incomplete: Windows patching, Oversized Windows ISOs, VHD/VHDX restore, NTFS Windows media, ext formatting, FreeDOS media")
        #expect(status.detailedWarning?.contains("VHD/VHDX restore") == true)
    }

    @Test
    func missingUEFINTFSOnlyDisablesOversizedWindowsISOPath() {
        let profile = windowsInstallerProfile(
            oversizedPaths: ["sources/install.wim", "sources/install-resources.cab"],
            requiresWIMSplit: false
        )
        let status = toolchain(
            available: [.wimlibImagex, .mkntfs, .ntfsPopulateHelper, .ntfsfix, .mke2fs, .qemuImg],
            missing: [.uefiNTFSImage]
        )

        let plan = WritePlanBuilder().buildPlan(
            for: profile,
            targetDisk: nil,
            toolchain: status
        )

        #expect(plan.isBlocked)
        #expect(plan.blockingReason?.contains("Oversized Windows ISO") == true)
        #expect(status.summaryLine.contains("Oversized Windows ISOs"))
    }

    @Test
    func readyToolchainUsesBundleReadinessCopy() {
        let status = toolchain(available: [.wimlibImagex, .uefiNTFSImage, .qemuImg, .mkntfs, .ntfsPopulateHelper, .ntfsfix, .mke2fs, .debugfs, .freedosBootHelper, .xz])
        #expect(status.readiness == .ready)
        #expect(status.summaryLine == "Self-contained bundle ready")
    }

    @Test
    func standaloneWIMBlocksUntilBootAssetsAreProvided() {
        let profile = standaloneInstallProfile()

        let plan = WritePlanBuilder().buildPlan(for: profile, targetDisk: nil, toolchain: toolchain())
        #expect(plan.isBlocked)
        #expect(plan.blockingReason?.contains("Boot Assets Source") == true)
    }

    @Test
    func standaloneWIMMergesWithBootAssetsIntoWindowsInstallerPlanning() {
        let merged = standaloneInstallProfile().mergedWithBootAssets(
            windowsInstallerProfile(oversizedPaths: [], requiresWIMSplit: false)
        )

        #expect(merged?.isWindowsInstaller == true)

        let plan = WritePlanBuilder().buildPlan(
            for: merged!,
            targetDisk: nil,
            toolchain: toolchain(available: [.wimlibImagex])
        )

        #expect(plan.mediaMode == .windowsInstaller)
        #expect(plan.isBlocked == false)
    }

    @Test
    func computesKnownHashes() async throws {
        let tempFile = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        try Data("abc".utf8).write(to: tempFile)
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let results = try await ImageHashService().computeHashes(
            for: tempFile,
            algorithms: [.md5, .sha1, .sha256]
        )
        let digests: [HashAlgorithm: String] = Dictionary(uniqueKeysWithValues: results.map { ($0.algorithm, $0.hexDigest) })

        #expect(digests[.md5] == "900150983cd24fb0d6963f7d28e17f72")
        #expect(digests[.sha1] == "a9993e364706816aba3e25717850c26c9cd0d89d")
        #expect(digests[.sha256] == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test
    func writeOptionsDefaultToVerificationAndSafeEject() {
        let options = WriteOptions()
        #expect(options.ejectWhenFinished)
        #expect(options.verifyWithSHA256)
        #expect(options.customizationProfile == .none)
        #expect(options.enableLinuxPersistence == false)
    }

    @Test
    func badBlockValidationPassesForRegularFiles() throws {
        let tempFile = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        try Data(repeating: 0, count: 512 * 1024).write(to: tempFile)
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let report = try BadBlockService().runDestructiveTest(
            onImageAt: tempFile,
            expectedCapacity: 512 * 1024,
            passCount: 1
        )

        #expect(report.suspectedFakeCapacity == false)
        #expect(report.badBlockCount == 0)
        #expect(report.bytesWritten == 512 * 1024)
        #expect(report.bytesTested == 512 * 1024)
    }

    @Test
    func badBlockValidationDetectsShortCapacity() throws {
        let tempFile = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        try Data(repeating: 0, count: 256 * 1024).write(to: tempFile)
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let report = try BadBlockService().runDestructiveTest(
            onImageAt: tempFile,
            expectedCapacity: 512 * 1024,
            passCount: 1
        )

        #expect(report.suspectedFakeCapacity)
        #expect(report.bytesWritten == 256 * 1024)
        #expect(report.notes.contains(where: { $0.contains("writable") }))
    }

    @Test
    func localDownloadsResumeIntoExistingPartialFiles() async throws {
        let tempDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let sourceURL = tempDirectory.appendingPathComponent("source.iso")
        let destinationURL = tempDirectory.appendingPathComponent("download.iso")
        let sourceData = Data((0..<250_000).map { UInt8($0 % 251) })
        try sourceData.write(to: sourceURL)
        try sourceData.prefix(32_768).write(to: destinationURL)

        let service = WindowsDownloadService()
        let job = try await service.download(title: "Windows 11", from: sourceURL, to: destinationURL)

        let downloadedData = try Data(contentsOf: destinationURL)
        #expect(downloadedData == sourceData)
        #expect(job.state == .completed)
        #expect(job.bytesReceived == Int64(sourceData.count))
        #expect(FileManager.default.fileExists(atPath: service.resumeMetadataURL(for: destinationURL).path()) == false)
    }

    @Test
    func catalogEntriesAreCachedWhenRequested() async throws {
        let tempDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let service = WindowsDownloadService()
        let entries = try await service.officialCatalogEntries(cacheDirectory: tempDirectory)
        let cacheURL = service.catalogCacheURL(in: tempDirectory)

        #expect(entries.count >= 2)
        #expect(FileManager.default.fileExists(atPath: cacheURL.path()))

        let cachedData = try Data(contentsOf: cacheURL)
        let decodedEntries = try JSONDecoder().decode([WindowsDownloadCatalogProduct].self, from: cachedData)
        #expect(decodedEntries == entries)
        #expect(entries.first?.releases.first?.editions.isEmpty == false)
        #expect(entries.contains(where: { $0.id == "windows11" }))
        #expect(entries.contains(where: { $0.id == "windows10" }))
    }

    @Test
    @MainActor
    func startupDegradationLogsOnlyOnceWithoutShowingAlert() {
        let model = AppModel()
        let degradedStatus = toolchain(missing: [.mkntfs])

        model.applyToolStatus(degradedStatus, announceStartupDegradation: true)
        let firstLogCount = model.logLines.filter { $0.contains("NTFS Windows media") }.count
        let firstAlertState = model.isShowingAlert

        model.isShowingAlert = false
        model.applyToolStatus(degradedStatus, announceStartupDegradation: true)
        let secondLogCount = model.logLines.filter { $0.contains("NTFS Windows media") }.count

        #expect(firstLogCount == 1)
        #expect(firstAlertState == false)
        #expect(secondLogCount == 1)
        #expect(model.isShowingAlert == false)
    }

    @Test
    func vendorAwareStrategySelectsRawWriteForProxmoxHybridInstaller() throws {
        let sourceURL = URL(fileURLWithPath: "/tmp/proxmox-ve_8.2.iso")
        let probe = ImageBinaryProbe.synthetic(
            sourceURL: sourceURL,
            declaredFormat: .iso,
            hasISO9660Marker: true,
            hasMBRSignature: true,
            isoHybridStyle: .hybridMBR
        )
        let classification = classificationResult(
            sourceURL: sourceURL,
            probe: probe,
            paths: ["pve-installer", "boot/grub/grub.cfg"],
            bootArtifacts: ["efi/boot/bootx64.efi"],
            hasEFI: true,
            hasBIOS: true
        )
        let profile = classifiedProfile(
            sourceURL: sourceURL,
            format: .iso,
            classification: classification,
            hasEFI: true,
            hasBIOS: true
        )

        let metadata = try WriteStrategyResolver().resolve(
            sourceProfile: profile,
            plan: directRawPlan(targetSystem: .dual),
            options: WriteOptions()
        )

        #expect(metadata.selectedWriteStrategy == .vendorProfileAwareWriter)
        #expect(metadata.underlyingWriter == .rawDeviceWriter)
        #expect(metadata.influencingProfile == .proxmoxVE)
        #expect(metadata.recommendedWriteStrategy == .preserveHybridDirectWrite)
    }

    @Test
    func genericCompressedRawImagesUseStreamedStrategy() throws {
        let sourceURL = URL(fileURLWithPath: "/tmp/router.img.xz")
        let profile = classifiedProfile(
            sourceURL: sourceURL,
            format: .dd,
            classification: nil
        )

        let metadata = try WriteStrategyResolver().resolve(
            sourceProfile: profile,
            plan: directRawPlan(),
            options: WriteOptions()
        )

        #expect(metadata.selectedWriteStrategy == .streamedDecompressionWriter)
        #expect(metadata.underlyingWriter == .rawDeviceWriter)
        #expect(metadata.decompressionStreamingActive == true)
        #expect(metadata.streamingCompression == .xz)
    }

    @Test
    func unsafeOpenWrtFirmwareArtifactsAreRejected() {
        let sourceURL = URL(fileURLWithPath: "/tmp/openwrt-23.05-sysupgrade.bin")
        let probe = ImageBinaryProbe.synthetic(
            sourceURL: sourceURL,
            declaredFormat: .dd,
            hasMBRSignature: true
        )
        let classification = classificationResult(sourceURL: sourceURL, probe: probe)
        let profile = classifiedProfile(
            sourceURL: sourceURL,
            format: .dd,
            classification: classification
        )

        #expect(classification.matchedVendorProfile == .openWrt)

        #expect(throws: BackendWritePipelineError.self) {
            _ = try WriteStrategyResolver().resolve(
                sourceProfile: profile,
                plan: directRawPlan(),
                options: WriteOptions()
            )
        }
    }

    @Test
    func pfSenseMemstickSerialRoutingPreservesVariantMetadata() throws {
        let sourceURL = URL(fileURLWithPath: "/tmp/pfSense-memstick-serial.img.gz")
        let probe = ImageBinaryProbe.synthetic(
            sourceURL: sourceURL,
            declaredFormat: .dd,
            compression: .gzip,
            hasGzipMagic: true,
            hasMBRSignature: true
        )
        let classification = classificationResult(sourceURL: sourceURL, probe: probe)
        let profile = classifiedProfile(
            sourceURL: sourceURL,
            format: .dd,
            classification: classification
        )

        let metadata = try WriteStrategyResolver().resolve(
            sourceProfile: profile,
            plan: directRawPlan(),
            options: WriteOptions()
        )

        #expect(metadata.selectedWriteStrategy == .vendorProfileAwareWriter)
        #expect(metadata.underlyingWriter == .rawDeviceWriter)
        #expect(metadata.decompressionStreamingActive == true)
        #expect(metadata.influencingProfile == .pfSense)
        #expect(metadata.influencingProfileVariant == "serial")
        #expect(metadata.recommendedWriteStrategy == .memstickRawWrite)
    }

    @Test
    func preflightRejectsAmbiguousTargets() async throws {
        let target = sampleDisk()
        let service = WritePreflightService(
            listExternalDisks: {
                [
                    target,
                    ExternalDisk(
                        identifier: target.identifier + "-shadow",
                        deviceNode: target.deviceNode,
                        mediaName: "Shadow",
                        volumeName: nil,
                        size: target.size,
                        busProtocol: target.busProtocol,
                        removable: true,
                        ejectable: true,
                        writable: true
                    ),
                ]
            },
            diskInfo: { _ in
                [
                    "WholeDisk": true,
                    "DeviceNode": target.deviceNode,
                    "TotalSize": target.size,
                    "WritableMedia": true,
                    "Internal": false,
                    "Removable": true,
                ]
            },
            mountedPartitions: { _ in [] }
        )

        await #expect(throws: BackendWritePipelineError.self) {
            _ = try await service.validate(
                targetDisk: target,
                sourceProfile: classifiedProfile(
                    sourceURL: URL(fileURLWithPath: "/tmp/generic.img"),
                    format: .dd,
                    classification: nil
                ),
                metadata: genericExecutionMetadata(),
                options: WriteOptions()
            )
        }
    }

    @Test
    func preflightRejectsNonRemovableTargetsWithoutOverride() async throws {
        let target = sampleDisk()
        let service = WritePreflightService(
            listExternalDisks: { [] },
            diskInfo: { _ in
                [
                    "WholeDisk": true,
                    "DeviceNode": target.deviceNode,
                    "TotalSize": target.size,
                    "WritableMedia": true,
                    "Internal": true,
                    "Removable": false,
                ]
            },
            mountedPartitions: { _ in [] }
        )

        await #expect(throws: BackendWritePipelineError.self) {
            _ = try await service.validate(
                targetDisk: target,
                sourceProfile: classifiedProfile(
                    sourceURL: URL(fileURLWithPath: "/tmp/generic.img"),
                    format: .dd,
                    classification: nil
                ),
                metadata: genericExecutionMetadata(),
                options: WriteOptions()
            )
        }
    }

    @Test
    func rawDeviceWriterBuildsStreamingPipelineForBzip2Input() async throws {
        let command = StreamedDecompressionCommand(
            compression: .bzip2,
            executable: "/usr/bin/bzip2",
            arguments: ["-dc", "/tmp/openwrt.img.bz2"],
            logicalSizeHint: 1_024
        )

        let client = RecordingPrivilegedClient()
        let service = RawDeviceWriterService(
            privileged: PrivilegedCommandService(client: client)
        )
        _ = try await service.write(
            input: .streamed(command),
            to: "/dev/rdisk9",
            expectedBytes: nil,
            targetExpectation: nil,
            phase: "Restoring image",
            message: "Streaming the bzip2-compressed raw image into the raw device."
        )

        let recorded = await client.snapshotRawWriteRequests()
        #expect(recorded.count == 1)
        #expect(recorded[0].streamExecutablePath == "/usr/bin/bzip2")
        #expect(recorded[0].streamArguments == ["-dc", "/tmp/openwrt.img.bz2"])
        #expect(recorded[0].destinationDeviceNode == "/dev/rdisk9")
    }

    @Test
    func genericValidationPassesForReadableFat32BootMedia() async throws {
        let root = try makeValidationRoot(
            files: [
                "EFI/BOOT/BOOTX64.EFI": Data("efi".utf8),
                "boot/grub/grub.cfg": Data("set timeout=5".utf8),
            ]
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let service = PostWriteValidationService(
            snapshotProvider: { _ in
                MediaTargetSnapshot(
                    wholeDiskIdentifier: "disk9",
                    deviceNode: "/dev/disk9",
                    partitionTableReadable: true,
                    partitions: [
                        ValidationPartitionSnapshot(
                            identifier: "disk9s1",
                            deviceNode: "/dev/disk9s1",
                            mountPoint: root,
                            filesystemDescription: "MS-DOS FAT32",
                            contentDescription: "Microsoft Basic Data"
                        ),
                    ]
                )
            }
        )

        let result = await service.validateWrittenMedia(
            sourceProfile: classifiedProfile(
                sourceURL: URL(fileURLWithPath: "/tmp/linux.iso"),
                format: .iso,
                classification: nil,
                hasEFI: true,
                hasBIOS: true
            ),
            targetDisk: sampleDisk(),
            plan: extractedFat32Plan(),
            executionMetadata: nil,
            destinationRoot: root,
            ntfsDestinationPartition: nil,
            customization: .none,
            toolchain: toolchain(),
            ntfsPopulateService: NTFSPopulateService()
        )

        #expect(result.passed)
        #expect(result.depth == .full)
        #expect(result.checksPerformed.contains(where: { $0.identifier == "partition-table" && $0.status == .passed }))
        #expect(result.checksPerformed.contains(where: { $0.identifier == "efi-boot-path" && $0.status == .passed }))
    }

    @Test
    func proxmoxValidationRecognizesHybridInstallerStructure() async throws {
        let root = try makeValidationRoot(
            files: [
                "EFI/BOOT/BOOTX64.EFI": Data("efi".utf8),
                "boot/grub/grub.cfg": Data("menuentry Proxmox".utf8),
                "pve-installer": Data(),
            ]
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let sourceURL = URL(fileURLWithPath: "/tmp/proxmox-ve.iso")
        let classification = classificationResult(
            sourceURL: sourceURL,
            probe: ImageBinaryProbe.synthetic(
                sourceURL: sourceURL,
                declaredFormat: .iso,
                hasISO9660Marker: true,
                hasMBRSignature: true,
                isoHybridStyle: .hybridMBR
            ),
            paths: ["pve-installer", "boot/grub/grub.cfg"],
            bootArtifacts: ["efi/boot/bootx64.efi"],
            hasEFI: true,
            hasBIOS: true
        )
        let service = PostWriteValidationService(
            snapshotProvider: { _ in
                MediaTargetSnapshot(
                    wholeDiskIdentifier: "disk9",
                    deviceNode: "/dev/disk9",
                    partitionTableReadable: true,
                    partitions: [
                        ValidationPartitionSnapshot(
                            identifier: "disk9s1",
                            deviceNode: "/dev/disk9s1",
                            mountPoint: root,
                            filesystemDescription: "ISO9660",
                            contentDescription: "CD_ROM_Mode_1"
                        ),
                    ]
                )
            }
        )

        let result = await service.validateWrittenMedia(
            sourceProfile: classifiedProfile(
                sourceURL: sourceURL,
                format: .iso,
                classification: classification,
                hasEFI: true,
                hasBIOS: true
            ),
            targetDisk: sampleDisk(),
            plan: directRawPlan(),
            executionMetadata: BackendWriteExecutionMetadata(
                selectedWriteStrategy: .vendorProfileAwareWriter,
                underlyingWriter: .rawDeviceWriter,
                decompressionStreamingActive: false,
                streamingCompression: nil,
                influencingProfile: .proxmoxVE,
                influencingProfileVariant: "installer-hybrid",
                recommendedWriteStrategy: .preserveHybridDirectWrite,
                safetyPolicy: .safeToProceed,
                policyExceptionsUsed: [],
                requiresDetachFlow: true,
                helperProtocolVersion: nil,
                helperPID: nil,
                workerPID: nil,
                workerCommand: nil
            ),
            destinationRoot: nil,
            ntfsDestinationPartition: nil,
            customization: .none,
            toolchain: toolchain(),
            ntfsPopulateService: NTFSPopulateService()
        )

        #expect(result.passed)
        #expect(result.matchedProfile == VendorProfileID.proxmoxVE)
        #expect(result.checksPerformed.contains(where: { $0.identifier == "vendor-proxmox-config" && $0.status == MediaValidationCheckStatus.passed }))
    }

    @Test
    func truenasValidationRecognizesInstallerStructure() async throws {
        let root = try makeValidationRoot(
            files: [
                "boot/loader.efi": Data("efi".utf8),
                "boot/defaults/loader.conf": Data("loader_conf".utf8),
            ]
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let sourceURL = URL(fileURLWithPath: "/tmp/truenas.iso")
        let classification = classificationResult(
            sourceURL: sourceURL,
            probe: ImageBinaryProbe.synthetic(sourceURL: sourceURL, declaredFormat: .iso, hasISO9660Marker: true),
            paths: ["boot/defaults/loader.conf", "boot/loader.efi"],
            bootArtifacts: ["boot/loader.efi"],
            hasEFI: true,
            hasBIOS: false
        )
        let service = PostWriteValidationService(
            snapshotProvider: { _ in
                MediaTargetSnapshot(
                    wholeDiskIdentifier: "disk9",
                    deviceNode: "/dev/disk9",
                    partitionTableReadable: true,
                    partitions: [
                        ValidationPartitionSnapshot(
                            identifier: "disk9s1",
                            deviceNode: "/dev/disk9s1",
                            mountPoint: root,
                            filesystemDescription: "MS-DOS FAT32",
                            contentDescription: "EFI System Partition"
                        ),
                    ]
                )
            }
        )

        let result = await service.validateWrittenMedia(
            sourceProfile: classifiedProfile(
                sourceURL: sourceURL,
                format: .iso,
                classification: classification,
                hasEFI: true,
                hasBIOS: false
            ),
            targetDisk: sampleDisk(),
            plan: extractedFat32Plan(),
            executionMetadata: nil,
            destinationRoot: root,
            ntfsDestinationPartition: nil,
            customization: .none,
            toolchain: toolchain(),
            ntfsPopulateService: NTFSPopulateService()
        )

        #expect(result.passed)
        #expect(result.matchedProfile == .trueNAS)
        #expect(result.checksPerformed.contains(where: { $0.identifier == "vendor-truenas-loader" && $0.status == .passed }))
    }

    @Test
    func openWrtValidationMarksAcceptedRawImagesAsPlausible() async {
        let sourceURL = URL(fileURLWithPath: "/tmp/openwrt-x86-64-combined.img.gz")
        let classification = classificationResult(
            sourceURL: sourceURL,
            probe: ImageBinaryProbe.synthetic(
                sourceURL: sourceURL,
                declaredFormat: .dd,
                compression: .gzip,
                hasGzipMagic: true,
                hasMBRSignature: true
            )
        )
        let service = PostWriteValidationService(
            snapshotProvider: { _ in
                MediaTargetSnapshot(
                    wholeDiskIdentifier: "disk9",
                    deviceNode: "/dev/disk9",
                    partitionTableReadable: true,
                    partitions: [
                        ValidationPartitionSnapshot(
                            identifier: "disk9s1",
                            deviceNode: "/dev/disk9s1",
                            mountPoint: nil,
                            filesystemDescription: "Linux",
                            contentDescription: "Linux Filesystem"
                        ),
                        ValidationPartitionSnapshot(
                            identifier: "disk9s2",
                            deviceNode: "/dev/disk9s2",
                            mountPoint: nil,
                            filesystemDescription: "Linux",
                            contentDescription: "Linux Filesystem"
                        ),
                    ]
                )
            }
        )

        let result = await service.validateWrittenMedia(
            sourceProfile: classifiedProfile(
                sourceURL: sourceURL,
                format: .dd,
                classification: classification
            ),
            targetDisk: sampleDisk(),
            plan: directRawPlan(),
            executionMetadata: genericExecutionMetadata(),
            destinationRoot: nil,
            ntfsDestinationPartition: nil,
            customization: .none,
            toolchain: toolchain(),
            ntfsPopulateService: NTFSPopulateService()
        )

        #expect(result.passed)
        #expect(result.matchedProfile == .openWrt)
        #expect(result.structurallyPlausibleButNotGuaranteedBootable)
    }

    @Test
    func opnsenseValidationPreservesSerialVariantMetadata() async throws {
        let root = try makeValidationRoot(
            files: [
                "boot/loader.efi": Data("efi".utf8),
                "boot/defaults/loader.conf": Data("console=\"comconsole\"".utf8),
            ]
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let sourceURL = URL(fileURLWithPath: "/tmp/opnsense-memstick-serial.img")
        let classification = classificationResult(
            sourceURL: sourceURL,
            probe: ImageBinaryProbe.synthetic(sourceURL: sourceURL, declaredFormat: .dd, hasMBRSignature: true)
        )
        let service = PostWriteValidationService(
            snapshotProvider: { _ in
                MediaTargetSnapshot(
                    wholeDiskIdentifier: "disk9",
                    deviceNode: "/dev/disk9",
                    partitionTableReadable: true,
                    partitions: [
                        ValidationPartitionSnapshot(
                            identifier: "disk9s1",
                            deviceNode: "/dev/disk9s1",
                            mountPoint: root,
                            filesystemDescription: "UFS",
                            contentDescription: "FreeBSD"
                        ),
                    ]
                )
            }
        )

        let result = await service.validateWrittenMedia(
            sourceProfile: classifiedProfile(
                sourceURL: sourceURL,
                format: .dd,
                classification: classification
            ),
            targetDisk: sampleDisk(),
            plan: directRawPlan(),
            executionMetadata: genericExecutionMetadata(),
            destinationRoot: nil,
            ntfsDestinationPartition: nil,
            customization: .none,
            toolchain: toolchain(),
            ntfsPopulateService: NTFSPopulateService()
        )

        #expect(result.passed)
        #expect(result.matchedProfile == .opnSense)
        #expect(result.profileVariant == "serial")
        #expect(result.profileNotes.contains(where: { $0.contains("serial") }))
    }

    @Test
    func pfSenseValidationPreservesVgaVariantMetadata() async throws {
        let root = try makeValidationRoot(
            files: [
                "boot/loader.efi": Data("efi".utf8),
                "boot/defaults/loader.conf": Data("console=\"vidconsole\"".utf8),
            ]
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let sourceURL = URL(fileURLWithPath: "/tmp/pfSense-memstick-vga.img")
        let classification = classificationResult(
            sourceURL: sourceURL,
            probe: ImageBinaryProbe.synthetic(sourceURL: sourceURL, declaredFormat: .dd, hasMBRSignature: true)
        )
        let service = PostWriteValidationService(
            snapshotProvider: { _ in
                MediaTargetSnapshot(
                    wholeDiskIdentifier: "disk9",
                    deviceNode: "/dev/disk9",
                    partitionTableReadable: true,
                    partitions: [
                        ValidationPartitionSnapshot(
                            identifier: "disk9s1",
                            deviceNode: "/dev/disk9s1",
                            mountPoint: root,
                            filesystemDescription: "UFS",
                            contentDescription: "FreeBSD"
                        ),
                    ]
                )
            }
        )

        let result = await service.validateWrittenMedia(
            sourceProfile: classifiedProfile(
                sourceURL: sourceURL,
                format: .dd,
                classification: classification
            ),
            targetDisk: sampleDisk(),
            plan: directRawPlan(),
            executionMetadata: genericExecutionMetadata(),
            destinationRoot: nil,
            ntfsDestinationPartition: nil,
            customization: .none,
            toolchain: toolchain(),
            ntfsPopulateService: NTFSPopulateService()
        )

        #expect(result.passed)
        #expect(result.matchedProfile == .pfSense)
        #expect(result.profileVariant == "vga")
        #expect(result.profileNotes.contains(where: { $0.contains("vga") }))
    }

    @Test
    func validationFailureCapturesExactReasonAndCheckMetadata() async throws {
        let root = try makeValidationRoot(
            files: [
                "EFI/BOOT/BOOTX64.EFI": Data("efi".utf8),
            ]
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let sourceURL = URL(fileURLWithPath: "/tmp/proxmox-ve.iso")
        let classification = classificationResult(
            sourceURL: sourceURL,
            probe: ImageBinaryProbe.synthetic(
                sourceURL: sourceURL,
                declaredFormat: .iso,
                hasISO9660Marker: true,
                hasMBRSignature: true,
                isoHybridStyle: .hybridMBR
            ),
            paths: ["pve-installer", "boot/grub/grub.cfg"],
            bootArtifacts: ["efi/boot/bootx64.efi"],
            hasEFI: true,
            hasBIOS: true
        )
        let service = PostWriteValidationService(
            snapshotProvider: { _ in
                MediaTargetSnapshot(
                    wholeDiskIdentifier: "disk9",
                    deviceNode: "/dev/disk9",
                    partitionTableReadable: true,
                    partitions: [
                        ValidationPartitionSnapshot(
                            identifier: "disk9s1",
                            deviceNode: "/dev/disk9s1",
                            mountPoint: root,
                            filesystemDescription: "ISO9660",
                            contentDescription: "CD_ROM_Mode_1"
                        ),
                    ]
                )
            }
        )

        let result = await service.validateWrittenMedia(
            sourceProfile: classifiedProfile(
                sourceURL: sourceURL,
                format: .iso,
                classification: classification,
                hasEFI: true,
                hasBIOS: true
            ),
            targetDisk: sampleDisk(),
            plan: directRawPlan(),
            executionMetadata: genericExecutionMetadata(),
            destinationRoot: nil,
            ntfsDestinationPartition: nil,
            customization: .none,
            toolchain: toolchain(),
            ntfsPopulateService: NTFSPopulateService()
        )

        #expect(result.passed == false)
        #expect(result.failureReason?.contains("Missing the expected Proxmox installer boot configuration markers.") == true)
        #expect(result.checksPerformed.contains(where: { $0.identifier == "vendor-proxmox-config" && $0.status == .failed }))
        #expect(result.matchedProfile == .proxmoxVE)
    }

    private func windowsInstallerProfile(
        oversizedPaths: [String],
        requiresWIMSplit: Bool,
        installImageSize: Int64 = SourceImageProfile.fat32MaximumFileSize + 1
    ) -> SourceImageProfile {
        SourceImageProfile(
            sourceURL: URL(fileURLWithPath: "/tmp/windows.iso"),
            format: .iso,
            size: 6_000_000_000,
            detectedVolumeName: "CCCOMA_X64FRE_EN-US_DV9",
            hasEFI: true,
            hasBIOS: true,
            oversizedPaths: oversizedPaths,
            bootArtifactPaths: ["efi/boot/bootx64.efi", "boot/bootfix.bin"],
            supportedMediaModes: [.windowsInstaller],
            notes: [],
            windows: WindowsImageProfile(
                installImageRelativePath: "sources/install.wim",
                installImageSize: installImageSize,
                hasBootWIM: true,
                hasPantherUnattend: false,
                isWinPE: false,
                needsWindows7EFIFallback: false,
                requiresWIMSplit: requiresWIMSplit,
                requiresBIOSWinPEFixup: false,
                prefersPantherCustomization: true
            ),
            supportsDOSBoot: false,
            supportsLinuxBoot: false,
            supportsPersistence: false,
            persistenceFlavor: .none,
            secureBootValidationCandidate: true,
            downloadFamily: .windows
        )
    }

    private func standaloneInstallProfile() -> SourceImageProfile {
        SourceImageProfile(
            sourceURL: URL(fileURLWithPath: "/tmp/install.wim"),
            format: .wim,
            size: 5_000_000_000,
            detectedVolumeName: nil,
            hasEFI: false,
            hasBIOS: false,
            oversizedPaths: ["install.wim"],
            bootArtifactPaths: [],
            supportedMediaModes: [],
            notes: [],
            windows: WindowsImageProfile(
                installImageRelativePath: "install.wim",
                installImageSize: 5_000_000_000,
                hasBootWIM: false,
                hasPantherUnattend: false,
                isWinPE: false,
                needsWindows7EFIFallback: false,
                requiresWIMSplit: true,
                requiresBIOSWinPEFixup: false,
                prefersPantherCustomization: false
            ),
            supportsDOSBoot: false,
            supportsLinuxBoot: false,
            supportsPersistence: false,
            persistenceFlavor: .none,
            secureBootValidationCandidate: false,
            downloadFamily: nil
        )
    }

    private func toolchain(
        available: Set<HelperTool> = [],
        missing: Set<HelperTool> = []
    ) -> ToolchainStatus {
        let alwaysAvailableSystemTools: Set<HelperTool> = [.diskutil, .hdiutil, .dd, .newfsMsdos, .newfsUdf, .shasum]
        let resolvedAvailable = alwaysAvailableSystemTools.union(available).subtracting(missing)
        let tools = Dictionary(uniqueKeysWithValues: HelperTool.allCases.map { tool in
            let isAvailable = resolvedAvailable.contains(tool)
            let path = isAvailable ? "/tmp/\(tool.rawValue)" : nil
            let source: ToolSource = if isAvailable {
                tool.isBundledRuntimeRequirement ? .bundled : .system
            } else {
                .missing
            }
            let validationState: ToolValidationState = isAvailable ? .ready : .missing
            return (
                tool,
                ToolAvailability(
                    tool: tool,
                    path: path,
                    source: source,
                    validationState: validationState,
                    validationMessage: nil
                )
            )
        })
        return ToolchainStatus(tools: tools)
    }

    private func makeResourceDirectory() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let resourceDirectory = root.appending(path: "Resources")
        try FileManager.default.createDirectory(at: resourceDirectory.appending(path: "Helpers"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: resourceDirectory.appending(path: "UEFI"), withIntermediateDirectories: true)
        return resourceDirectory
    }

    private func makeExecutable(at url: URL, body: String) throws {
        try body.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path())
    }

    private func makeValidationRoot(files: [String: Data]) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        for (relativePath, data) in files {
            let fileURL = root.appending(path: relativePath)
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: fileURL)
        }

        return root
    }

    private func sampleDisk() -> ExternalDisk {
        ExternalDisk(
            identifier: "disk9",
            deviceNode: "/dev/disk9",
            mediaName: "Sample USB",
            volumeName: "SAMPLE",
            size: 16_000_000_000,
            busProtocol: "USB",
            removable: true,
            ejectable: true,
            writable: true
        )
    }

    private actor SnapshotRecorder {
        private var storage: [Int64] = []

        func append(_ value: Int64) {
            storage.append(value)
        }

        func values() -> [Int64] {
            storage
        }
    }

    private actor RecordingPrivilegedClient: PrivilegedOperationClient {
        struct SubprocessRequest: Sendable {
            let executable: String
            let arguments: [String]
            let currentDirectoryPath: String?
            let phase: String
            let message: String
            let expectedTotalBytes: Int64?
        }

        struct RawWriteRequest: Sendable {
            let sourceFilePath: String?
            let streamExecutablePath: String?
            let streamArguments: [String]
            let destinationDeviceNode: String
            let expectedBytes: Int64?
            let targetExpectation: PrivilegedTargetExpectation?
        }

        private var subprocessRequests: [SubprocessRequest] = []
        private var rawWriteRequests: [RawWriteRequest] = []

        func runSubprocess(
            executable: String,
            arguments: [String],
            currentDirectory: URL?,
            progressParser: PrivilegedSubprocessProgressParser,
            expectedTotalBytes: Int64?,
            phase: String,
            message: String,
            eventHandler: PrivilegedWorkerEventHandler?
        ) async throws -> PrivilegedOperationResult {
            subprocessRequests.append(
                SubprocessRequest(
                    executable: executable,
                    arguments: arguments,
                    currentDirectoryPath: currentDirectory?.path(),
                    phase: phase,
                    message: message,
                    expectedTotalBytes: expectedTotalBytes
                )
            )

            return PrivilegedOperationResult(
                helperProtocolVersion: PrivilegedHelperConstants.protocolVersion,
                helperPID: 700,
                childPID: 701,
                bytesTransferred: expectedTotalBytes,
                standardOutput: "",
                standardError: ""
            )
        }

        func writeRaw(
            sourceFilePath: String?,
            streamExecutablePath: String?,
            streamArguments: [String],
            destinationDeviceNode: String,
            expectedBytes: Int64?,
            phase: String,
            message: String,
            targetExpectation: PrivilegedTargetExpectation?,
            eventHandler: PrivilegedWorkerEventHandler?
        ) async throws -> PrivilegedOperationResult {
            rawWriteRequests.append(
                RawWriteRequest(
                    sourceFilePath: sourceFilePath,
                    streamExecutablePath: streamExecutablePath,
                    streamArguments: streamArguments,
                    destinationDeviceNode: destinationDeviceNode,
                    expectedBytes: expectedBytes,
                    targetExpectation: targetExpectation
                )
            )

            return PrivilegedOperationResult(
                helperProtocolVersion: PrivilegedHelperConstants.protocolVersion,
                helperPID: 700,
                childPID: streamExecutablePath == nil ? nil : 701,
                bytesTransferred: expectedBytes,
                standardOutput: "",
                standardError: ""
            )
        }

        func snapshotSubprocessRequests() -> [SubprocessRequest] {
            subprocessRequests
        }

        func snapshotRawWriteRequests() -> [RawWriteRequest] {
            rawWriteRequests
        }

        func captureRaw(
            sourceDeviceNode: String,
            destinationFilePath: String,
            expectedBytes: Int64,
            phase: String,
            message: String,
            targetExpectation: PrivilegedTargetExpectation?,
            eventHandler: PrivilegedWorkerEventHandler?
        ) async throws -> PrivilegedOperationResult {
            PrivilegedOperationResult(
                helperProtocolVersion: PrivilegedHelperConstants.protocolVersion,
                helperPID: 700,
                childPID: nil,
                bytesTransferred: expectedBytes,
                standardOutput: "",
                standardError: ""
            )
        }
    }

    private actor FailingPrivilegedClient: PrivilegedOperationClient {
        private let error: PrivilegedHelperClientError

        init(error: PrivilegedHelperClientError) {
            self.error = error
        }

        func runSubprocess(
            executable: String,
            arguments: [String],
            currentDirectory: URL?,
            progressParser: PrivilegedSubprocessProgressParser,
            expectedTotalBytes: Int64?,
            phase: String,
            message: String,
            eventHandler: PrivilegedWorkerEventHandler?
        ) async throws -> PrivilegedOperationResult {
            throw error
        }

        func writeRaw(
            sourceFilePath: String?,
            streamExecutablePath: String?,
            streamArguments: [String],
            destinationDeviceNode: String,
            expectedBytes: Int64?,
            phase: String,
            message: String,
            targetExpectation: PrivilegedTargetExpectation?,
            eventHandler: PrivilegedWorkerEventHandler?
        ) async throws -> PrivilegedOperationResult {
            throw error
        }

        func captureRaw(
            sourceDeviceNode: String,
            destinationFilePath: String,
            expectedBytes: Int64,
            phase: String,
            message: String,
            targetExpectation: PrivilegedTargetExpectation?,
            eventHandler: PrivilegedWorkerEventHandler?
        ) async throws -> PrivilegedOperationResult {
            throw error
        }
    }

    private func directRawPlan(targetSystem: TargetSystem = .dual) -> WritePlan {
        WritePlan(
            mediaMode: .directImage,
            payloadMode: .directRaw,
            partitionScheme: .superFloppy,
            targetSystem: targetSystem,
            primaryFilesystem: nil,
            partitionLayouts: [],
            helperRequirements: [
                HelperRequirement(tool: .diskutil, reason: "Prepare and unmount the target disk"),
                HelperRequirement(tool: .dd, reason: "Write the source image directly to the raw device"),
            ],
            postWriteFixups: [],
            verificationMode: .rawByteCompare,
            verificationSteps: [],
            warnings: [],
            summary: "Direct raw write",
            isBlocked: false,
            blockingReason: nil
        )
    }

    private func extractedFat32Plan() -> WritePlan {
        WritePlan(
            mediaMode: .directImage,
            payloadMode: .fat32Extract,
            partitionScheme: .gpt,
            targetSystem: .uefi,
            primaryFilesystem: .fat32,
            partitionLayouts: [
                PartitionLayout(name: "BOOT", filesystem: .fat32, sizeMiB: nil, description: "Bootable extracted payload"),
            ],
            helperRequirements: [],
            postWriteFixups: [],
            verificationMode: .bootArtifacts,
            verificationSteps: [],
            warnings: [],
            summary: "Extracted FAT32 media",
            isBlocked: false,
            blockingReason: nil
        )
    }

    private func genericExecutionMetadata() -> BackendWriteExecutionMetadata {
        BackendWriteExecutionMetadata(
            selectedWriteStrategy: .rawDeviceWriter,
            underlyingWriter: .rawDeviceWriter,
            decompressionStreamingActive: false,
            streamingCompression: nil,
            influencingProfile: nil,
            influencingProfileVariant: nil,
            recommendedWriteStrategy: .rawDiskWrite,
            safetyPolicy: .safeToProceed,
            policyExceptionsUsed: [],
            requiresDetachFlow: true,
            helperProtocolVersion: nil,
            helperPID: nil,
            workerPID: nil,
            workerCommand: nil
        )
    }

    private func classifiedProfile(
        sourceURL: URL,
        format: SourceImageFormat,
        classification: ImageClassificationResult?,
        hasEFI: Bool = false,
        hasBIOS: Bool = false
    ) -> SourceImageProfile {
        SourceImageProfile(
            sourceURL: sourceURL,
            format: format,
            size: 1_000_000_000,
            detectedVolumeName: nil,
            hasEFI: hasEFI,
            hasBIOS: hasBIOS,
            oversizedPaths: [],
            bootArtifactPaths: hasEFI ? ["efi/boot/bootx64.efi"] : [],
            supportedMediaModes: [.directImage],
            notes: [],
            windows: nil,
            supportsDOSBoot: false,
            supportsLinuxBoot: false,
            supportsPersistence: false,
            persistenceFlavor: .none,
            secureBootValidationCandidate: hasEFI,
            downloadFamily: nil,
            isoHybridStyle: classification?.imageKind == .hybridISO ? .hybridMBR : .notApplicable,
            applianceProfile: nil,
            classification: classification
        )
    }

    private func classificationResult(
        sourceURL: URL,
        probe: ImageBinaryProbe,
        volumeName: String? = nil,
        paths: [String] = [],
        bootArtifacts: [String] = [],
        hasEFI: Bool = false,
        hasBIOS: Bool = false
    ) -> ImageClassificationResult {
        ImageClassifier().classify(
            ImageClassificationContext(
                sourceURL: sourceURL,
                probe: probe,
                layoutHints: ImageLayoutHints(
                    volumeName: volumeName,
                    relativePaths: Set(paths.map { $0.lowercased() }),
                    topLevelNames: Set(paths.compactMap { $0.split(separator: "/").first.map(String.init) }.map { $0.lowercased() })
                ),
                bootArtifactPaths: Set(bootArtifacts.map { $0.lowercased() }),
                hasEFI: hasEFI,
                hasBIOS: hasBIOS
            )
        )
    }

    private func makeOpticalImageFixture(at url: URL, hybridMBR: Bool) throws {
        let size = (20 * 2_048) + 2_048
        var bytes = Data(repeating: 0, count: size)

        if hybridMBR {
            bytes[446 + 4] = 0x17
            bytes[446 + 12] = 0x20
            bytes[510] = 0x55
            bytes[511] = 0xAA
        }

        let descriptorOffset = 16 * 2_048
        bytes[descriptorOffset] = 0x01
        for (offset, byte) in Array("CD001".utf8).enumerated() {
            bytes[descriptorOffset + 1 + offset] = byte
        }
        bytes[descriptorOffset + 6] = 0x01

        try bytes.write(to: url)
    }
}
