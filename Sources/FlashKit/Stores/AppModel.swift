import Foundation
import Observation

func isCancellationLikeError(_ error: Error) -> Bool {
    if error is CancellationError {
        return true
    }

    let nsError = error as NSError
    if nsError.domain == "Swift.CancellationError" {
        return true
    }

    return error.localizedDescription.contains("Swift.CancellationError")
}

@MainActor
@Observable
final class AppModel {
    var availableDisks: [ExternalDisk] = []
    var selectedDiskIdentifier: String?
    var sourceMode: SourceMode = .localFile
    var selectedImageURL: URL?
    var bootAssetsURL: URL?
    var sourceProfile: SourceImageProfile?
    var bootAssetsProfile: SourceImageProfile?
    var writePlan: WritePlan?
    var toolStatus = ToolchainStatus.empty
    var hashResults: [HashResult] = []
    var downloadCatalog: [WindowsDownloadCatalogProduct] = []
    var selectedDownloadFamily: DownloadCatalogFamily = .windows
    var selectedDownloadProductID: String?
    var selectedDownloadReleaseID: String?
    var selectedDownloadEditionID: String?
    var downloadLanguages: [WindowsDownloadLanguageOption] = []
    var selectedDownloadLanguageID: String?
    var downloadLinkOptions: [WindowsDownloadLinkOption] = []
    var selectedDownloadArchitecture: WindowsDownloadArchitecture = .x64
    var downloadJob: DownloadJob?
    var badBlockReport: BadBlockReport?
    var lastBadBlockReportURL: URL?
    var lastCaptureURL: URL?
    var writeOptions = WriteOptions()
    var volumeLabel = ""
    var badBlockPassCount = 1

    var isRefreshingDisks = false
    var isAnalyzing = false
    var isWriting = false
    var isHashing = false
    var isFetchingDownloadCatalog = false
    var isFetchingDownloadOptions = false
    var isDownloading = false
    var isTestingMedia = false
    var isCapturingDrive = false

    var currentPhase = ""
    var currentMessage = "Pick a Windows ISO and a removable USB disk."
    var progressFraction: Double?
    var logLines: [String] = []
    var privilegedHelperAvailability: PrivilegedHelperAvailability = .available
    var isInstallingPrivilegedHelper = false

    var alertMessage = ""
    var isShowingAlert = false

    private enum OperationKind: String {
        case write
        case badBlockTest
        case capture

        var displayName: String {
            switch self {
            case .write:
                return "write"
            case .badBlockTest:
                return "bad-block test"
            case .capture:
                return "drive capture"
            }
        }

        var cancellationMessage: String {
            switch self {
            case .write:
                return "Write cancelled."
            case .badBlockTest:
                return "Bad-block test cancelled."
            case .capture:
                return "Drive capture cancelled."
            }
        }
    }

    @ObservationIgnored private var hasAnnouncedStartupToolchainWarning = false
    @ObservationIgnored private var lastLoggedPlanSignature = ""
    @ObservationIgnored private var lastAutomaticVolumeLabel = ""
    @ObservationIgnored private var diskMonitorTask: Task<Void, Never>?
    @ObservationIgnored private var currentOperationTask: Task<Void, Never>?
    @ObservationIgnored private var currentOperationID: UUID?
    @ObservationIgnored private var currentOperationKind: OperationKind?
    @ObservationIgnored private let diskService = DiskService()
    @ObservationIgnored private let analyzer = ImageInspectionService()
    @ObservationIgnored private let hashService = ImageHashService()
    @ObservationIgnored private let planner = WritePlanBuilder()
    @ObservationIgnored private let writer = MediaWriterService()
    @ObservationIgnored private let downloadService = WindowsDownloadService()
    @ObservationIgnored private let badBlockService = BadBlockService()
    @ObservationIgnored private let driveImagingService = DriveImagingService()
    @ObservationIgnored private let privilegedHelperStatusService = PrivilegedHelperStatusService()
    @ObservationIgnored private let privilegedHelperInstallService = PrivilegedHelperInstallService()

    var selectedDisk: ExternalDisk? {
        availableDisks.first { $0.identifier == selectedDiskIdentifier }
    }

    var canAnalyze: Bool {
        selectedImageURL != nil && !isBusy
    }

    var canWrite: Bool {
        selectedImageURL != nil && selectedDisk != nil && activeSourceProfile != nil && writePlan != nil && !isBusy
    }

    var canDownloadWindows: Bool {
        selectedDownloadLink != nil && !isBusy
    }

    var canRunBadBlockTest: Bool {
        selectedDisk != nil && !isBusy
    }

    var canCaptureDrive: Bool {
        selectedDisk != nil && !isBusy
    }

    var isBusy: Bool {
        isRefreshingDisks
            || isAnalyzing
            || isWriting
            || isHashing
            || isFetchingDownloadCatalog
            || isFetchingDownloadOptions
            || isDownloading
            || isTestingMedia
            || isCapturingDrive
    }

    var writeBlocker: String? {
        writePlan?.blockingReason
    }

    var planWarnings: [String] {
        writePlan?.warnings ?? []
    }

    var writeButtonTitle: String {
        canCancelCurrentOperation ? "Cancel" : "Write"
    }

    var canCancelCurrentOperation: Bool {
        currentOperationTask != nil
    }

    var visibleDownloadCatalog: [WindowsDownloadCatalogProduct] {
        downloadCatalog.filter { $0.family == selectedDownloadFamily }
    }

    var activeSourceProfile: SourceImageProfile? {
        if let sourceProfile, sourceProfile.requiresBootAssetsSource {
            return sourceProfile.mergedWithBootAssets(bootAssetsProfile) ?? sourceProfile
        }
        return sourceProfile
    }

    var selectedDownloadProduct: WindowsDownloadCatalogProduct? {
        visibleDownloadCatalog.first { $0.id == selectedDownloadProductID } ?? visibleDownloadCatalog.first
    }

    var selectedDownloadRelease: WindowsDownloadRelease? {
        selectedDownloadProduct?.releases.first { $0.id == selectedDownloadReleaseID } ?? selectedDownloadProduct?.releases.first
    }

    var selectedDownloadEdition: WindowsDownloadEdition? {
        selectedDownloadRelease?.editions.first { $0.id == selectedDownloadEditionID } ?? selectedDownloadRelease?.editions.first
    }

    var selectedDownloadLanguage: WindowsDownloadLanguageOption? {
        downloadLanguages.first { $0.id == selectedDownloadLanguageID } ?? downloadLanguages.first
    }

    var selectedDownloadLink: WindowsDownloadLinkOption? {
        downloadLinkOptions.first { $0.architecture == selectedDownloadArchitecture }
            ?? downloadLinkOptions.first
    }

    var downloadSuggestedFilename: String {
        selectedDownloadLink?.filename ?? "Windows.iso"
    }

    var shouldShowBootAssetsPicker: Bool {
        sourceProfile?.requiresBootAssetsSource == true
    }

    var shouldShowPrivilegedHelperPrompt: Bool {
        !privilegedHelperAvailability.isAvailable
    }

    func bootstrap() async {
        await refreshPrivilegedHelperAvailability()
        await refreshToolStatus(announceStartupDegradation: true)
        await refreshDisks()
        startDiskMonitoringIfNeeded()
    }

    func refreshPrivilegedHelperAvailability() async {
        privilegedHelperAvailability = await privilegedHelperStatusService.availability()
    }

    func installPrivilegedHelper() async {
        guard !isInstallingPrivilegedHelper else {
            return
        }

        isInstallingPrivilegedHelper = true
        defer { isInstallingPrivilegedHelper = false }

        do {
            appendLog("Installing the privileged helper from the current FlashKit app bundle.")
            try await privilegedHelperInstallService.installBundledHelper()
            appendLog("Privileged helper installed successfully.")
            await refreshPrivilegedHelperAvailability()
            await refreshToolStatus()
        } catch {
            if isCancellationLikeError(error) {
                appendLog("Privileged helper installation cancelled.")
            } else {
                presentError(error.localizedDescription)
            }
        }
    }

    func setSourceMode(_ mode: SourceMode) async {
        sourceMode = mode
        if mode == .downloadWindows && downloadCatalog.isEmpty {
            await refreshDownloadCatalog()
        } else if mode == .bundledFreeDOS {
            await selectBundledFreeDOS()
        }
    }

    func refreshToolStatus(announceStartupDegradation: Bool = false) async {
        let status = await writer.detectToolStatus()
        applyToolStatus(status, announceStartupDegradation: announceStartupDegradation)
    }

    func refreshDisks() async {
        isRefreshingDisks = true
        defer { isRefreshingDisks = false }

        do {
            let disks = try await diskService.listExternalDisks()
            applyDiskSnapshot(disks, source: .manual)
        } catch {
            presentError(error.localizedDescription)
        }
    }

    func setSelectedImage(_ url: URL) async {
        sourceMode = .localFile
        selectedImageURL = url
        bootAssetsURL = nil
        sourceProfile = nil
        bootAssetsProfile = nil
        writePlan = nil
        hashResults = []
        downloadJob = nil
        badBlockReport = nil
        progressFraction = nil
        currentPhase = "Image selected"
        currentMessage = url.lastPathComponent
        appendLog("Selected source image: \(url.path())")
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.analyzeSelectedImage() }
            group.addTask { await self.computeAutomaticHash() }
        }
    }

    func analyzeSelectedImage() async {
        guard let selectedImageURL else {
            return
        }

        isAnalyzing = true
        currentPhase = "Analyzing image"
        currentMessage = "Inspecting \(selectedImageURL.lastPathComponent)."
        progressFraction = nil

        defer { isAnalyzing = false }

        do {
            let profile = try await analyzer.inspectImage(at: selectedImageURL)
            self.sourceProfile = profile
            if !profile.requiresBootAssetsSource {
                bootAssetsURL = nil
                bootAssetsProfile = nil
            }
            currentPhase = activeSourceProfile?.headline ?? profile.headline
            currentMessage = activeSourceProfile?.summaryLine ?? profile.summaryLine

            applyAutomaticVolumeLabel(from: activeSourceProfile ?? profile)

            appendLog("Analysis complete: \(profile.format.rawValue), supported modes \(profile.supportedMediaModes.map(\.rawValue).joined(separator: ", ")).")
            for line in BackendActivityLogFormatter.classificationLines(for: activeSourceProfile ?? profile) {
                appendLog(line)
            }
            if profile.windows?.requiresWIMSplit == true {
                appendLog("Large \(profile.windows?.installImageRelativePath ?? "install.wim") detected. Split mode will be required for FAT32.")
            }
            if let warning = profile.warningSummary {
                appendLog(warning)
            }
            rebuildWritePlan()
        } catch {
            presentError(error.localizedDescription)
        }
    }

    func setBootAssetsSource(_ url: URL) async {
        bootAssetsURL = url
        bootAssetsProfile = nil
        currentPhase = "Inspecting boot assets"
        currentMessage = url.lastPathComponent
        appendLog("Selected boot assets source: \(url.path())")

        do {
            let profile = try await analyzer.inspectImage(at: url)
            bootAssetsProfile = profile
            currentPhase = "Boot assets ready"
            currentMessage = profile.summaryLine
            applyAutomaticVolumeLabel(from: activeSourceProfile ?? profile)
            rebuildWritePlan()
        } catch {
            presentError(error.localizedDescription)
        }
    }

    private func applyAutomaticVolumeLabel(from profile: SourceImageProfile) {
        let suggestedLabel = profile.applianceProfile?.recommendedVolumeLabel ?? profile.recommendedVolumeLabel
        let shouldReplace = volumeLabel.isEmpty
            || volumeLabel == lastAutomaticVolumeLabel
            || volumeLabel == VolumeLabelFormatter.legacyDefaultLabel

        if shouldReplace {
            volumeLabel = suggestedLabel
        }

        lastAutomaticVolumeLabel = suggestedLabel
    }

    func refreshDownloadCatalog() async {
        isFetchingDownloadCatalog = true
        defer { isFetchingDownloadCatalog = false }

        do {
            let catalog = try await downloadService.officialCatalogEntries()
            downloadCatalog = catalog
            let visible = visibleDownloadCatalog
            selectedDownloadProductID = selectedDownloadProductID ?? visible.first?.id
            selectedDownloadReleaseID = selectedDownloadReleaseID ?? selectedDownloadProduct?.releases.first?.id
            selectedDownloadEditionID = selectedDownloadEditionID ?? selectedDownloadRelease?.editions.first?.id
            appendLog("Loaded the official download catalog.")
            await refreshDownloadLanguages()
        } catch {
            presentError(error.localizedDescription)
        }
    }

    func refreshDownloadLanguages() async {
        guard let product = selectedDownloadProduct,
              let release = selectedDownloadRelease,
              let edition = selectedDownloadEdition else {
            downloadLanguages = []
            downloadLinkOptions = []
            return
        }

        isFetchingDownloadOptions = true
        defer { isFetchingDownloadOptions = false }

        do {
            let languages = try await downloadService.loadLanguages(for: product, release: release, edition: edition)
            downloadLanguages = languages
            selectedDownloadLanguageID = selectedDownloadLanguageID ?? preferredLanguageID(in: languages)
            appendLog("Loaded \(languages.count) download option group(s) for \(product.title) \(release.title).")
            await refreshDownloadLinks()
        } catch {
            presentError(error.localizedDescription)
        }
    }

    func refreshDownloadLinks() async {
        guard let product = selectedDownloadProduct,
              let language = selectedDownloadLanguage else {
            downloadLinkOptions = []
            return
        }

        isFetchingDownloadOptions = true
        defer { isFetchingDownloadOptions = false }

        do {
            let links = try await downloadService.loadDownloadLinks(for: product, language: language)
            downloadLinkOptions = links
            if !links.contains(where: { $0.architecture == selectedDownloadArchitecture }) {
                selectedDownloadArchitecture = links.first?.architecture ?? .x64
            }
            appendLog("Loaded official download links for \(language.displayName).")
        } catch {
            presentError(error.localizedDescription)
        }
    }

    func handleDownloadProductChange() async {
        selectedDownloadReleaseID = selectedDownloadProduct?.releases.first?.id
        selectedDownloadEditionID = selectedDownloadRelease?.editions.first?.id
        selectedDownloadLanguageID = nil
        await refreshDownloadLanguages()
    }

    func handleDownloadFamilyChange() async {
        let visible = visibleDownloadCatalog
        selectedDownloadProductID = visible.first?.id
        selectedDownloadReleaseID = visible.first?.releases.first?.id
        selectedDownloadEditionID = visible.first?.releases.first?.editions.first?.id
        selectedDownloadLanguageID = nil
        await refreshDownloadLanguages()
    }

    func handleDownloadReleaseChange() async {
        selectedDownloadEditionID = selectedDownloadRelease?.editions.first?.id
        selectedDownloadLanguageID = nil
        await refreshDownloadLanguages()
    }

    func handleDownloadEditionChange() async {
        selectedDownloadLanguageID = nil
        await refreshDownloadLanguages()
    }

    func handleDownloadLanguageChange() async {
        await refreshDownloadLinks()
    }

    func downloadSelectedWindows(to destinationURL: URL) async {
        guard let selectedDownloadLink else {
            return
        }

        isDownloading = true
        currentPhase = "Downloading Windows"
        currentMessage = "Downloading \(selectedDownloadLink.filename)."
        progressFraction = nil
        alertMessage = ""
        isShowingAlert = false

        defer { isDownloading = false }

        do {
            let job = try await downloadService.download(
                title: selectedDownloadLink.displayName,
                from: selectedDownloadLink.url,
                to: destinationURL
            )
            downloadJob = job
            appendLog("Downloaded \(selectedDownloadLink.filename) from the selected official source.")
            await setSelectedImage(destinationURL)
        } catch {
            presentError(error.localizedDescription)
        }
    }

    func computeAutomaticHash() async {
        guard let selectedImageURL else {
            return
        }

        isHashing = true
        defer { isHashing = false }

        do {
            let isDirectory = (try? selectedImageURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            guard !isDirectory else {
                hashResults = []
                return
            }

            let hashes = try await hashService.computeHashes(for: selectedImageURL, algorithms: HashAlgorithm.allCases)
            hashResults = hashes
            for hash in hashes {
                appendLog("Computed \(hash.algorithm.displayName): \(hash.hexDigest)")
            }
        } catch {
            appendLog("Hashing failed: \(error.localizedDescription)")
        }
    }

    func refreshPlanForSelectionChange() {
        rebuildWritePlan()
    }

    func writeSelectedMedia() async {
        await runTrackedOperation(kind: .write) { [self] in
            await self.performWriteSelectedMedia()
        }
    }

    private func performWriteSelectedMedia() async {
        guard let selectedImageURL, let selectedDisk, let activeSourceProfile, let writePlan else {
            return
        }

        isWriting = true
        currentPhase = "Starting write"
        currentMessage = "Preparing \(selectedDisk.deviceNode)."
        progressFraction = 0.0
        isShowingAlert = false
        alertMessage = ""

        defer { isWriting = false }

        do {
            if shouldShowPrivilegedHelperPrompt {
                appendLog("Privileged helper unavailable; using the macOS administrator password prompt for privileged commands.")
            }

            let progressHandler: @Sendable (WriteSessionUpdate) async -> Void = { [weak self] update in
                await MainActor.run {
                    self?.apply(update)
                }
            }

            try await writer.writeImage(
                sourceImageURL: selectedImageURL,
                profile: activeSourceProfile,
                plan: writePlan,
                targetDisk: selectedDisk,
                volumeLabel: volumeLabel,
                options: writeOptions,
                bootAssetsURL: bootAssetsURL,
                toolchain: toolStatus,
                progress: progressHandler
            )

            appendLog("Write completed successfully.")
            await refreshDisks()
        } catch {
            if isCancellationLikeError(error) {
                handleCancellation(of: .write)
                await refreshDisks()
            } else {
                presentError(error.localizedDescription)
            }
        }
    }

    func runBadBlockTest() async {
        await runTrackedOperation(kind: .badBlockTest) { [self] in
            await self.performBadBlockTest()
        }
    }

    private func performBadBlockTest() async {
        guard let selectedDisk else {
            return
        }

        isTestingMedia = true
        currentPhase = "Testing media"
        currentMessage = "Running destructive media validation on \(selectedDisk.displayName)."
        progressFraction = nil
        badBlockReport = nil
        lastBadBlockReportURL = nil
        defer { isTestingMedia = false }

        do {
            let report = try await badBlockService.runDestructiveTest(on: selectedDisk, passCount: badBlockPassCount)
            badBlockReport = report
            let reportURL = try persistBadBlockReport(report, for: selectedDisk)
            lastBadBlockReportURL = reportURL

            if report.suspectedFakeCapacity || report.badBlockCount > 0 {
                currentPhase = "Validation found issues"
                currentMessage = "The selected drive reported capacity or read-back problems."
            } else {
                currentPhase = "Validation finished"
                currentMessage = "The selected drive completed destructive validation cleanly."
            }

            appendLog("Bad-block validation finished with \(report.badBlockCount) mismatches across \(report.bytesTested) tested bytes.")
            appendLog("Saved bad-block report: \(reportURL.path())")
            await refreshDisks()
        } catch {
            if isCancellationLikeError(error) {
                handleCancellation(of: .badBlockTest)
                await refreshDisks()
            } else {
                presentError(error.localizedDescription)
            }
        }
    }

    func captureSelectedDisk(to destinationURL: URL, format: DriveCaptureFormat) async {
        await runTrackedOperation(kind: .capture) { [self] in
            await self.performCaptureSelectedDisk(to: destinationURL, format: format)
        }
    }

    private func performCaptureSelectedDisk(to destinationURL: URL, format: DriveCaptureFormat) async {
        guard let selectedDisk else {
            return
        }

        isCapturingDrive = true
        currentPhase = "Capturing drive"
        currentMessage = "Preparing \(selectedDisk.displayName) for capture."
        progressFraction = 0.0
        lastCaptureURL = nil
        isShowingAlert = false
        alertMessage = ""

        defer { isCapturingDrive = false }

        do {
            let progressHandler: @Sendable (WriteSessionUpdate) async -> Void = { [weak self] update in
                await MainActor.run {
                    self?.apply(update)
                }
            }

            try await driveImagingService.captureImage(
                targetDisk: selectedDisk,
                destinationURL: destinationURL,
                format: format,
                toolchain: toolStatus,
                progress: progressHandler
            )

            lastCaptureURL = destinationURL
            appendLog("Drive capture completed: \(destinationURL.path())")
            await refreshDisks()
        } catch {
            if isCancellationLikeError(error) {
                handleCancellation(of: .capture)
                await refreshDisks()
            } else {
                presentError(error.localizedDescription)
            }
        }
    }

    func cancelCurrentOperation() {
        guard let currentOperationTask, let currentOperationKind else {
            return
        }

        currentPhase = "Cancelling"
        currentMessage = "Stopping the current \(currentOperationKind.displayName)."
        appendLog("Cancelling \(currentOperationKind.displayName).")
        currentOperationTask.cancel()
    }

    private func apply(_ update: WriteSessionUpdate) {
        currentPhase = update.phase
        currentMessage = update.message
        progressFraction = update.fractionCompleted
        if update.shouldLogMessage {
            appendLog("\(update.phase): \(update.message)")
        }
        for detail in update.details {
            appendLog(detail)
        }
    }

    func applyToolStatus(_ status: ToolchainStatus, announceStartupDegradation: Bool = false) {
        toolStatus = status

        if announceStartupDegradation,
           !hasAnnouncedStartupToolchainWarning,
           let detailedWarning = status.detailedWarning {
            appendLog(detailedWarning)
            hasAnnouncedStartupToolchainWarning = true
        }

        rebuildWritePlan()
    }

    private func rebuildWritePlan() {
        guard let activeSourceProfile else {
            writePlan = nil
            lastLoggedPlanSignature = ""
            return
        }

        let plan = planner.buildPlan(for: activeSourceProfile, targetDisk: selectedDisk, toolchain: toolStatus, options: writeOptions)
        writePlan = plan
        currentMessage = plan.summary

        let planLines = BackendActivityLogFormatter.planLines(for: activeSourceProfile, plan: plan, volumeLabel: volumeLabel)
        let signature = planLines.joined(separator: "\n")
        if signature != lastLoggedPlanSignature {
            for line in planLines {
                appendLog(line)
            }
            lastLoggedPlanSignature = signature
        }

        if let blockingReason = plan.blockingReason {
            appendLog("Plan blocked: \(blockingReason)")
        }
    }

    private func presentError(_ message: String) {
        currentPhase = "Stopped"
        currentMessage = message
        alertMessage = message
        isShowingAlert = true
        appendLog("Error: \(message)")
    }

    private func handleCancellation(of operationKind: OperationKind) {
        currentPhase = "Cancelled"
        currentMessage = operationKind.cancellationMessage
        progressFraction = nil
        appendLog(operationKind.cancellationMessage)
    }

    private func runTrackedOperation(
        kind: OperationKind,
        operation: @escaping @MainActor () async -> Void
    ) async {
        guard currentOperationTask == nil else {
            return
        }

        let operationID = UUID()
        currentOperationID = operationID
        currentOperationKind = kind

        let task = Task { @MainActor [weak self] in
            await operation()

            guard let self, self.currentOperationID == operationID else {
                return
            }

            self.currentOperationTask = nil
            self.currentOperationID = nil
            self.currentOperationKind = nil
        }

        currentOperationTask = task
        await task.value
    }

    private func startDiskMonitoringIfNeeded() {
        guard diskMonitorTask == nil else {
            return
        }

        diskMonitorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else {
                    return
                }
                await self.refreshDisksFromMonitorIfNeeded()
            }
        }
    }

    private func refreshDisksFromMonitorIfNeeded() async {
        guard !isRefreshingDisks, !isWriting, !isTestingMedia, !isCapturingDrive else {
            return
        }

        do {
            let disks = try await diskService.listExternalDisks()
            guard disks != availableDisks else {
                return
            }

            applyDiskSnapshot(disks, source: .monitor)
        } catch {
            // Ignore transient diskutil failures during background monitoring.
        }
    }

    private enum DiskSnapshotSource {
        case manual
        case monitor
    }

    private func applyDiskSnapshot(_ disks: [ExternalDisk], source: DiskSnapshotSource) {
        let previousDisks = availableDisks
        let previousIdentifiers = Set(previousDisks.map(\.identifier))
        let newIdentifiers = Set(disks.map(\.identifier))

        availableDisks = disks

        if let selectedDiskIdentifier, disks.contains(where: { $0.identifier == selectedDiskIdentifier }) {
            // Keep the current selection.
        } else {
            selectedDiskIdentifier = disks.first?.identifier
        }

        switch source {
        case .manual:
            appendLog("Discovered \(availableDisks.count) removable disk(s).")
        case .monitor:
            let addedDisks = disks.filter { !previousIdentifiers.contains($0.identifier) }
            let removedDisks = previousDisks.filter { !newIdentifiers.contains($0.identifier) }

            for disk in addedDisks {
                appendLog("USB detected: \(disk.displayName) (\(disk.deviceNode)).")
            }

            for disk in removedDisks {
                appendLog("USB removed: \(disk.displayName) (\(disk.deviceNode)).")
            }
        }

        rebuildWritePlan()
    }

    private func appendLog(_ message: String) {
        let timestamp = Date.now.formatted(date: .omitted, time: .standard)
        logLines.append("[\(timestamp)] \(message)")

        if logLines.count > 120 {
            logLines.removeFirst(logLines.count - 120)
        }
    }

    private func persistBadBlockReport(_ report: BadBlockReport, for disk: ExternalDisk) throws -> URL {
        let reportsDirectory = try applicationSupportDirectory().appending(path: "Reports", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: reportsDirectory, withIntermediateDirectories: true)

        let timestamp = ISO8601DateFormatter().string(from: .now).replacingOccurrences(of: ":", with: "-")
        let filename = "\(sanitizedFilename(disk.displayName))-\(timestamp).json"
        let reportURL = reportsDirectory.appending(path: filename)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(report)
        try data.write(to: reportURL, options: .atomic)
        return reportURL
    }

    private func applicationSupportDirectory() throws -> URL {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library")
            .appending(path: "Application Support")
            .appending(path: "FlashKit", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func sanitizedFilename(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let mapped = name.unicodeScalars.map { scalar in
            invalid.contains(scalar) ? "_" : String(scalar)
        }.joined()
        return mapped.replacingOccurrences(of: " ", with: "_")
    }

    private func preferredLanguageID(in languages: [WindowsDownloadLanguageOption]) -> String? {
        if let english = languages.first(where: { $0.localeName.localizedCaseInsensitiveContains("english") }) {
            return english.id
        }
        return languages.first?.id
    }

    private func selectBundledFreeDOS() async {
        guard let bundledURL = bundledFreeDOSURL() else {
            presentError("The bundled FreeDOS assets were not found.")
            return
        }

        selectedImageURL = bundledURL
        bootAssetsURL = nil
        sourceProfile = nil
        bootAssetsProfile = nil
        writePlan = nil
        hashResults = []
        downloadJob = nil
        badBlockReport = nil
        progressFraction = nil
        currentPhase = "FreeDOS selected"
        currentMessage = "Bundled FreeDOS system files are ready."
        appendLog("Selected bundled FreeDOS assets: \(bundledURL.path())")
        await analyzeSelectedImage()
    }

    private func bundledFreeDOSURL() -> URL? {
        let candidates = [
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appending(path: "Resources").appending(path: "FreeDOS"),
            Bundle.main.resourceURL?.appending(path: "FreeDOS"),
        ].compactMap { $0 }

        return candidates.first(where: { FileManager.default.fileExists(atPath: $0.path()) })
    }
}
