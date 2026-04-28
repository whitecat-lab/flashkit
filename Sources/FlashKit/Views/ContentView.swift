import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Bindable var model: AppModel

    @AppStorage("targetDiskListHeight") private var targetDiskListHeight = 128.0
    @State private var isWriteConfirmationPresented = false
    @State private var isBadBlockConfirmationPresented = false
    @State private var isAdvancedExpanded = false
    @State private var isActivityLogExpanded = false
    @State private var targetDiskListResizeStartHeight: Double?
    @State private var scrollViewportHeight: CGFloat = 0
    @State private var scrollContentHeight: CGFloat = 0
    @State private var pendingWindowAdjustment: WindowAdjustment?
    private let savePanelService = SavePanelService()
    private let openPanelService = OpenPanelService()

    private let supportedImageTypes: [UTType] = [
        UTType(filenameExtension: "iso"),
        UTType(filenameExtension: "img"),
        UTType(filenameExtension: "raw"),
        UTType(filenameExtension: "gz"),
        UTType(filenameExtension: "xz"),
        UTType(filenameExtension: "dmg"),
        UTType(filenameExtension: "wim"),
        UTType(filenameExtension: "esd"),
        UTType(filenameExtension: "vhd"),
        UTType(filenameExtension: "vhdx"),
    ].compactMap { $0 }

    private let bootAssetsTypes: [UTType] = [
        .folder,
        UTType(filenameExtension: "iso"),
        UTType(filenameExtension: "dmg"),
    ].compactMap { $0 }

    private enum WindowAdjustment {
        case expand
        case shrink
    }

    var body: some View {
        VStack(spacing: 0) {
            dragHandle

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    header
                    if model.shouldShowPrivilegedHelperPrompt {
                        privilegedHelperPrompt
                    }
                    sourcePanel
                    targetAndWritePanels
                    advancedPanel
                    activityLogPanel
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    GeometryReader { proxy in
                        Color.clear
                            .onAppear {
                                updateScrollContentHeight(proxy.size.height)
                            }
                            .onChange(of: proxy.size.height) { _, newHeight in
                                updateScrollContentHeight(newHeight)
                            }
                    }
                }
            }
            .background {
                GeometryReader { proxy in
                    Color.clear
                        .onAppear {
                            updateScrollViewportHeight(proxy.size.height)
                        }
                        .onChange(of: proxy.size.height) { _, newHeight in
                            updateScrollViewportHeight(newHeight)
                        }
                }
            }
        }
        .background(background)
        .overlay {
            if model.isShowingWriteCompletion {
                WriteCompletionOverlay {
                    model.dismissWriteCompletion()
                }
                .transition(.scale(scale: 0.94).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.86), value: model.isShowingWriteCompletion)
        .confirmationDialog(
            "Erase \(model.selectedDisk?.displayName ?? "the selected disk")?",
            isPresented: $isWriteConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button(model.writeButtonTitle, role: .destructive) {
                Task {
                    await model.writeSelectedMedia()
                }
            }
        } message: {
            Text(writeConfirmationMessage)
        }
        .confirmationDialog(
            "Run destructive bad-block testing on \(model.selectedDisk?.displayName ?? "the selected disk")?",
            isPresented: $isBadBlockConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Run Bad Block Test", role: .destructive) {
                Task {
                    await model.runBadBlockTest()
                }
            }
        } message: {
            Text("This will overwrite the selected USB disk with validation patterns for \(model.badBlockPassCount) pass(es).")
        }
        .alert("FlashKit", isPresented: $model.isShowingAlert) {
            if let title = model.alertActionTitle,
               let url = model.alertActionURL {
                Button(title) {
                    NSWorkspace.shared.open(url)
                }
            }
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.alertMessage)
        }
        .task {
            await model.bootstrap()
        }
        .onChange(of: model.selectedDiskIdentifier) { _, _ in
            model.refreshPlanForSelectionChange()
        }
        .onChange(of: model.selectedDownloadProductID) { _, _ in
            Task {
                await model.handleDownloadProductChange()
            }
        }
        .onChange(of: model.selectedDownloadFamily) { _, _ in
            Task {
                await model.handleDownloadFamilyChange()
            }
        }
        .onChange(of: model.selectedDownloadReleaseID) { _, _ in
            Task {
                await model.handleDownloadReleaseChange()
            }
        }
        .onChange(of: model.selectedDownloadEditionID) { _, _ in
            Task {
                await model.handleDownloadEditionChange()
            }
        }
        .onChange(of: model.selectedDownloadLanguageID) { _, _ in
            Task {
                await model.handleDownloadLanguageChange()
            }
        }
        .onChange(of: model.isShowingWriteCompletion) { _, isShowing in
            if isShowing {
                NSApp.requestUserAttention(.informationalRequest)
            }
        }
    }

    private var dragHandle: some View {
        Color.clear
        .frame(maxWidth: .infinity)
        .frame(height: 12)
        .background(.clear)
        .contentShape(Rectangle())
        .gesture(WindowDragGesture())
        .allowsWindowActivationEvents(true)
        .overlay(alignment: .bottom) {
            Divider()
                .opacity(0.45)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("FlashKit")
                .font(.system(size: 24, weight: .bold, design: .rounded))

            Text(appVersionLabel)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    private var appVersionLabel: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "dev"
        guard let build = info["CFBundleVersion"] as? String,
              !build.isEmpty
        else {
            return "v\(version)"
        }
        return "v\(version) (\(build))"
    }

    private var privilegedHelperPrompt: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "lock.open.trianglebadge.exclamationmark")
                .font(.title3)
                .foregroundStyle(.orange)

            VStack(alignment: .leading, spacing: 3) {
                Text("Install the privileged helper")
                    .font(.subheadline.weight(.semibold))

                Text(model.privilegedHelperAvailability.bannerMessage ?? "FlashKit can install its privileged helper from the current app bundle.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            Button {
                Task {
                    await model.installPrivilegedHelper()
                }
            } label: {
                if model.isInstallingPrivilegedHelper {
                    Label("Installing…", systemImage: "hourglass")
                } else {
                    Label("Install Helper", systemImage: "arrow.down.circle")
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(model.isInstallingPrivilegedHelper)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            Color.orange.opacity(0.08),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.3), lineWidth: 1)
        )
    }

    private var sourcePanel: some View {
        panel(title: "Source Image", subtitle: "Pick a Windows ISO or any other bootable image.") {
            VStack(alignment: .leading, spacing: 10) {
                localSourceControls

                if model.sourceMode == .downloadWindows {
                    downloadSourceControls
                }

                if shouldShowSourceDetails {
                    VStack(alignment: .leading, spacing: 8) {
                        if shouldShowSourceStatus {
                            HStack(alignment: .center, spacing: 8) {
                                if isSourceStatusBusy {
                                    ProgressView()
                                        .controlSize(.small)
                                }

                                VStack(alignment: .leading, spacing: 2) {
                                    if let sourcePhaseText {
                                        Text(sourcePhaseText)
                                            .font(.footnote.weight(.semibold))
                                            .foregroundStyle(.secondary)
                                    }

                                    if let sourceMessageText {
                                        Text(sourceMessageText)
                                            .font(.footnote)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }

                        if model.shouldShowBootAssetsPicker {
                            Divider()

                            HStack(spacing: 12) {
                                Button {
                                    chooseBootAssetsSource()
                                } label: {
                                    Label(model.bootAssetsURL == nil ? "Choose Boot Assets" : "Change Boot Assets", systemImage: "shippingbox")
                                }

                                if model.bootAssetsURL == nil {
                                    warningLabel("Standalone WIM/ESD media needs a Windows ISO or extracted setup directory as Boot Assets Source.")
                                }
                            }

                            Text(model.bootAssetsURL?.path() ?? "No boot assets source selected yet.")
                                .font(.footnote.monospaced())
                                .foregroundStyle(model.bootAssetsURL == nil ? .secondary : .primary)
                                .textSelection(.enabled)
                        }

                        if let downloadJob = model.downloadJob {
                            Text("Last download: \(downloadJob.destinationURL.path())")
                                .font(.footnote.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
        }
    }

    private var targetPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Target USB")
                .font(.title3.weight(.semibold))

            VStack(alignment: .leading, spacing: 3) {
                Text("Volume Label")
                    .font(.footnote.weight(.semibold))

                TextField("Auto", text: $model.volumeLabel)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .frame(maxWidth: 220)
                    .disabled(model.writePlan?.mediaMode != .windowsInstaller || model.isBusy)
            }

            if model.availableDisks.isEmpty {
                HStack(alignment: .center, spacing: 12) {
                    warningLabel("No removable USB disks were found. Plug in a target drive.")

                    Spacer(minLength: 12)

                    ejectWhenFinishedToggle
                }
            } else {
                List(model.availableDisks, selection: $model.selectedDiskIdentifier) { disk in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(disk.displayName)
                            .font(.headline)
                        Text(disk.detailLine)
                            .font(.footnote.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                    .tag(Optional(disk.identifier))
                }
                .frame(height: resolvedTargetDiskListHeight)
                .listStyle(.inset(alternatesRowBackgrounds: true))
                .overlay(alignment: .bottomTrailing) {
                    targetDiskResizeHandle
                        .offset(x: -2, y: -2)
                }
            }

            if model.activeSourceProfile?.supportsPersistence == true {
                Divider()

                VStack(alignment: .leading, spacing: 12) {
                    Text("Linux Persistence")
                        .font(.subheadline.weight(.semibold))

                    Toggle("Create a persistence partition", isOn: persistenceEnabledBinding)
                        .disabled(model.isBusy)

                    Stepper(
                        "Persistence size: \(model.writeOptions.linuxPersistenceSizeMiB) MiB",
                        value: persistenceSizeBinding,
                        in: 1_024...32_768,
                        step: 1_024
                    )
                    .disabled(!model.writeOptions.enableLinuxPersistence || model.isBusy)
                }
            }

            if let blocker = model.writeBlocker {
                warningLabel(blocker)
            } else {
                ForEach(model.planWarnings, id: \.self) { warning in
                    warningLabel(warning)
                }
            }

            if !model.availableDisks.isEmpty {
                HStack {
                    Spacer()

                    ejectWhenFinishedToggle
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.quaternary, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.04), radius: 12, y: 6)
    }

    private var targetAndWritePanels: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 12) {
                targetPanel
                    .frame(maxWidth: .infinity, alignment: .topLeading)

                statusPanel
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }

            VStack(alignment: .leading, spacing: 12) {
                targetPanel
                statusPanel
            }
        }
        .animation(nil, value: isActivityLogExpanded)
        .animation(nil, value: isAdvancedExpanded)
    }

    private var resolvedTargetDiskListHeight: CGFloat {
        min(max(targetDiskListHeight, 96), 320)
    }

    private var targetDiskResizeHandle: some View {
        Canvas { context, size in
            let strokeColor = Color.secondary.opacity(0.8)
            let spacing: CGFloat = 4
            let lineLength: CGFloat = 7

            for index in 0..<3 {
                let inset = CGFloat(index) * spacing
                var path = Path()
                path.move(to: CGPoint(x: size.width - lineLength - inset, y: size.height))
                path.addLine(to: CGPoint(x: size.width, y: size.height - lineLength - inset))
                context.stroke(path, with: .color(strokeColor), lineWidth: 1.5)
            }
        }
        .frame(width: 12, height: 12)
        .padding(4)
        .frame(width: 24, height: 24, alignment: .bottomTrailing)
        .contentShape(Rectangle())
        .accessibilityLabel("Resize USB list")
        .accessibilityHint("Drag to change the USB device list height.")
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                        let startHeight = targetDiskListResizeStartHeight ?? targetDiskListHeight
                        targetDiskListResizeStartHeight = startHeight
                        targetDiskListHeight = min(max(startHeight + value.translation.height, 96), 320)
                    }
                    .onEnded { _ in
                        targetDiskListResizeStartHeight = nil
                    }
            )
            .help("Drag to resize the USB list")
    }

    private var ejectWhenFinishedToggle: some View {
        Toggle("Eject the USB drive when finished", isOn: $model.writeOptions.ejectWhenFinished)
            .controlSize(.small)
            .disabled(model.isBusy)
            .toggleStyle(.checkbox)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: true)
    }

    private var statusPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                Text("Write")
                    .font(.title3.weight(.semibold))

                if let writePhaseText {
                    Text(writePhaseText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                Button(role: .destructive) {
                    if model.canCancelCurrentOperation {
                        model.cancelCurrentOperation()
                    } else {
                        isWriteConfirmationPresented = true
                    }
                } label: {
                    Label(model.writeButtonTitle, systemImage: model.canCancelCurrentOperation ? "xmark.circle" : "externaldrive.badge.minus")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(.red)
                .disabled((!model.canWrite || model.writeBlocker != nil) && !model.canCancelCurrentOperation)
            }

            if let writeMessageText {
                Text(writeMessageText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(3, reservesSpace: true)
                    .truncationMode(.middle)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(alignment: .firstTextBaseline, spacing: 12) {
                WriteProgressIndicator(
                    progressFraction: model.progressFraction,
                    isBusy: isWriteStatusBusy,
                    accessibilityValue: writeProgressAccessibilityValue
                )

                Text(writeProgressPercentText)
                    .font(.body.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 48, alignment: .trailing)
                    .contentTransition(.numericText())
                    .accessibilityHidden(true)
            }
            .padding(.top, 4)

            if let writeProgressDetailText {
                Text(writeProgressDetailText)
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityLabel("Write progress details")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.quaternary, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.04), radius: 12, y: 6)
    }

    private var visibleHashResults: [HashResult] {
        model.hashResults
    }

    private var sourceStatusPhases: Set<String> {
        [
            "Image selected",
            "Analyzing image",
            "Inspecting boot assets",
            "Boot assets ready",
            "Downloading Windows",
            "FreeDOS selected",
        ]
    }

    private var isSourceStatusBusy: Bool {
        model.isAnalyzing
            || model.isHashing
            || model.isDownloading
            || model.isFetchingDownloadCatalog
            || model.isFetchingDownloadOptions
    }

    private var shouldShowSourceStatus: Bool {
        isSourceStatusBusy || sourceStatusPhases.contains(model.currentPhase)
    }

    private var shouldShowSourceDetails: Bool {
        shouldShowSourceStatus
            || model.shouldShowBootAssetsPicker
            || model.downloadJob != nil
    }

    private var sourcePhaseText: String? {
        if model.isHashing {
            return "Computing checksums"
        }

        let phase = model.currentPhase.trimmingCharacters(in: .whitespacesAndNewlines)
        return phase.isEmpty ? nil : phase
    }

    private var sourceMessageText: String? {
        if model.isHashing {
            return "MD5, SHA-1, and SHA-256"
        }

        let message = model.currentMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? nil : message
    }

    private var isWriteStatusBusy: Bool {
        model.isWriting || model.isTestingMedia || model.isCapturingDrive
    }

    private var writePhaseText: String? {
        guard !shouldShowSourceStatus else {
            return nil
        }

        let phase = model.currentPhase.trimmingCharacters(in: .whitespacesAndNewlines)
        return phase.isEmpty ? nil : phase
    }

    private var writeMessageText: String? {
        guard !shouldShowSourceStatus else {
            return nil
        }

        let message = model.currentMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty, message != "Pick a Windows ISO and a removable USB disk." else {
            return nil
        }
        return message
    }

    private var writeProgressPercentText: String {
        if let completedBytes = model.progressCompletedBytes,
           let totalBytes = model.progressTotalBytes,
           totalBytes > 0 {
            return formattedPercent(Double(completedBytes) / Double(totalBytes))
        }

        if let progressFraction = model.progressFraction {
            return formattedPercent(progressFraction)
        }

        return isWriteStatusBusy ? "…" : "0%"
    }

    private var writeProgressDetailText: String? {
        guard let completedBytes = model.progressCompletedBytes,
              let totalBytes = model.progressTotalBytes,
              totalBytes > 0
        else {
            return nil
        }

        let completed = ByteCountFormatter.string(fromByteCount: completedBytes, countStyle: .file)
        let total = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
        if let rate = model.progressRateBytesPerSecond, rate > 0 {
            let rateText = ByteCountFormatter.string(fromByteCount: Int64(rate), countStyle: .file)
            return "\(completed) of \(total) • \(rateText)/s"
        }
        return "\(completed) of \(total)"
    }

    private var writeProgressAccessibilityValue: String {
        if let detail = writeProgressDetailText {
            return "\(writeProgressPercentText), \(detail)"
        }
        return writeProgressPercentText
    }

    private func formattedPercent(_ value: Double) -> String {
        let clamped = min(max(value, 0), 1)
        return clamped.formatted(.percent.precision(.fractionLength(clamped < 0.1 && clamped > 0 ? 1 : 0)))
    }

    private var activityTechnicalDetails: [String] {
        var details: [String] = []

        if let profile = model.activeSourceProfile {
            if let applianceProfile = profile.applianceProfile {
                details.append("Detected appliance: \(applianceProfile.displayName)")
            }
            details.append(profile.summaryLine)
            if let warningSummary = profile.warningSummary {
                details.append("Warning: \(warningSummary)")
            }

            if let writePlan = model.writePlan, writePlan.summary != profile.summaryLine {
                details.append(writePlan.summary)
            }

            if let installerFileName = profile.windows?.installImageRelativePath,
               let installerSize = profile.windows?.installImageSize {
                details.append("\(installerFileName) • \(ByteCountFormatter.string(fromByteCount: installerSize, countStyle: .binary))")
            }
        }

        details.append(contentsOf: visibleHashResults.map { "\($0.algorithm.displayName): \($0.hexDigest)" })

        var seen = Set<String>()
        return details.filter { seen.insert($0).inserted }
    }

    private var advancedPanel: some View {
        VStack(alignment: .leading, spacing: isAdvancedExpanded ? 8 : 0) {
            HStack(spacing: 12) {
                Text("Advanced")
                    .font(.title3.weight(.semibold))

                Spacer()

                Button {
                    toggleExpandableSection($isAdvancedExpanded)
                } label: {
                    Image(systemName: isAdvancedExpanded ? "minus.circle" : "plus.circle")
                        .font(.title3)
                        .padding(2)
                }
                .buttonStyle(.plain)
                .help(isAdvancedExpanded ? "Collapse Advanced" : "Expand Advanced")
            }

            if isAdvancedExpanded {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Destructive validation and drive capture.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    if model.activeSourceProfile?.isWindowsInstaller == true {
                        windowsSetupOptionsSection
                    }

                    if model.activeSourceProfile?.isWindowsInstaller == true,
                       model.selectedDisk != nil {
                        Divider()
                    }

                    if model.selectedDisk == nil {
                        warningLabel("Select a removable USB disk to use the advanced validation and capture tools.")
                    } else {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(alignment: .center, spacing: 12) {
                                Stepper("Bad-block passes: \(model.badBlockPassCount)", value: $model.badBlockPassCount, in: 1...4)
                                    .disabled(!model.canRunBadBlockTest)

                                Button(role: .destructive) {
                                    isBadBlockConfirmationPresented = true
                                } label: {
                                    Label("Run Bad Block Test", systemImage: "exclamationmark.triangle")
                                }
                                .disabled(!model.canRunBadBlockTest)
                            }

                            if let report = model.badBlockReport {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("Last validation result")
                                        .font(.subheadline.weight(.semibold))
                                    Text("Tested \(ByteCountFormatter.string(fromByteCount: report.bytesTested, countStyle: .binary)) • mismatches \(report.badBlockCount) • fake capacity \(report.suspectedFakeCapacity ? "suspected" : "not detected")")
                                        .font(.footnote.monospaced())
                                        .foregroundStyle(.secondary)
                                    ForEach(report.notes, id: \.self) { note in
                                        Text(note)
                                            .font(.footnote)
                                            .foregroundStyle(.secondary)
                                    }
                                    if let reportURL = model.lastBadBlockReportURL {
                                        Text(reportURL.path())
                                            .font(.footnote.monospaced())
                                            .foregroundStyle(.secondary)
                                            .textSelection(.enabled)
                                    }
                                }
                            }
                        }

                        Divider()

                        VStack(alignment: .leading, spacing: 12) {
                            Text("Image USB")
                                .font(.subheadline.weight(.semibold))

                            Menu {
                                Button {
                                    chooseCaptureDestination(format: .rawImage)
                                } label: {
                                    Label("Capture as .img", systemImage: "square.and.arrow.down")
                                }

                                Button {
                                    chooseCaptureDestination(format: .vhd)
                                } label: {
                                    Label("Capture as .vhd", systemImage: "internaldrive")
                                }

                                Button {
                                    chooseCaptureDestination(format: .vhdx)
                                } label: {
                                    Label("Capture as .vhdx", systemImage: "shippingbox")
                                }
                            } label: {
                                Label("Capture This Drive", systemImage: "square.and.arrow.down")
                            }
                            .disabled(!model.canCaptureDrive)
                            .controlSize(.small)

                            if let captureURL = model.lastCaptureURL {
                                Text(captureURL.path())
                                    .font(.footnote.monospaced())
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, isAdvancedExpanded ? 12 : 8)
        .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.quaternary, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.04), radius: 12, y: 6)
    }

    private var activityLogPanel: some View {
        VStack(alignment: .leading, spacing: isActivityLogExpanded ? 8 : 0) {
            HStack(spacing: 12) {
                Text("Activity Log")
                    .font(.title3.weight(.semibold))

                Spacer()

                Button {
                    toggleExpandableSection($isActivityLogExpanded)
                } label: {
                    Image(systemName: isActivityLogExpanded ? "minus.circle" : "plus.circle")
                        .font(.title3)
                        .padding(2)
                }
                .buttonStyle(.plain)
                .help(isActivityLogExpanded ? "Collapse Activity Log" : "Expand Activity Log")
            }

            if isActivityLogExpanded {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        if !activityTechnicalDetails.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Source details")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(.secondary)

                                ForEach(activityTechnicalDetails, id: \.self) { detail in
                                    Text(detail)
                                        .font(.footnote.monospaced())
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                }
                            }

                            if !model.logLines.isEmpty {
                                Divider()
                                    .padding(.vertical, 2)
                            }
                        }

                        if model.logLines.isEmpty {
                            Text("Nothing has run yet.")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(Array(model.logLines.enumerated()), id: \.offset) { _, line in
                                Text(line)
                                    .font(.footnote.monospaced())
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 140, maxHeight: 220)
                .padding(12)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(.quaternary, lineWidth: 1)
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, isActivityLogExpanded ? 12 : 8)
        .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.quaternary, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.04), radius: 12, y: 6)
    }

    private var windowsSetupOptionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Windows Setup Options")
                .font(.subheadline.weight(.semibold))

            Toggle("Prefer a local account", isOn: localAccountToggleBinding)
                .disabled(model.isBusy)

            TextField("Local account name", text: localAccountNameBinding)
                .textFieldStyle(.roundedBorder)
                .disabled(!model.writeOptions.customizationProfile.preferLocalAccount || model.isBusy)

            Toggle("Bypass Secure Boot / TPM / RAM checks", isOn: bypassRequirementsBinding)
                .disabled(model.isBusy)

            Toggle("Bypass online-account requirement", isOn: bypassOnlineAccountBinding)
                .disabled(model.isBusy)

            Toggle("Disable data collection / privacy prompts", isOn: skipPrivacyBinding)
                .disabled(model.isBusy)

            Toggle("Duplicate this Mac's locale into setup and OOBE", isOn: duplicateLocaleBinding)
                .disabled(model.isBusy)

            Toggle("Disable BitLocker / device encryption", isOn: disableBitLockerBinding)
                .disabled(model.isBusy)

            Toggle("Use Microsoft 2023 bootloaders when available", isOn: useMicrosoft2023BootloadersBinding)
                .disabled(model.isBusy)
        }
    }

    private var writeConfirmationMessage: String {
        let disk = model.selectedDisk?.displayName ?? "selected disk"
        let device = model.selectedDisk?.deviceNode ?? "unknown device"
        let strategy = model.writePlan?.mediaMode.rawValue ?? "Unknown strategy"
        return "This will erase \(disk) (\(device)) and use \(strategy.lowercased())."
    }

    private var background: some View {
        Color(nsColor: .windowBackgroundColor)
        .ignoresSafeArea()
    }

    private func panel<Content: View>(title: String, subtitle: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.title3.weight(.semibold))

                if !subtitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.quaternary, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.04), radius: 12, y: 6)
    }

    private func warningLabel(_ text: String) -> some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
        }
        .font(.footnote)
        .foregroundStyle(.orange)
    }

    private var localAccountToggleBinding: Binding<Bool> {
        Binding(
            get: { model.writeOptions.customizationProfile.preferLocalAccount },
            set: {
                model.writeOptions.customizationProfile.preferLocalAccount = $0
                model.refreshPlanForSelectionChange()
            }
        )
    }

    private func toggleExpandableSection(_ isExpanded: Binding<Bool>) {
        let willExpand = !isExpanded.wrappedValue
        withAnimation(.easeInOut(duration: 0.18)) {
            isExpanded.wrappedValue.toggle()
        }

        pendingWindowAdjustment = willExpand ? .expand : .shrink
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
            attemptWindowAdjustmentIfNeeded(forceFinalize: true)
        }
    }

    private func updateScrollViewportHeight(_ newHeight: CGFloat) {
        guard abs(scrollViewportHeight - newHeight) > 0.5 else {
            return
        }

        scrollViewportHeight = newHeight
        attemptWindowAdjustmentIfNeeded()
    }

    private func updateScrollContentHeight(_ newHeight: CGFloat) {
        guard abs(scrollContentHeight - newHeight) > 0.5 else {
            return
        }

        scrollContentHeight = newHeight
        attemptWindowAdjustmentIfNeeded()
    }

    private func attemptWindowAdjustmentIfNeeded(forceFinalize: Bool = false) {
        guard let pendingWindowAdjustment else {
            return
        }

        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else {
            return
        }

        let currentFrame = window.frame
        let screenFrame = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? currentFrame
        let delta = scrollContentHeight - scrollViewportHeight

        switch pendingWindowAdjustment {
        case .expand:
            guard delta > 12 else {
                if forceFinalize {
                    self.pendingWindowAdjustment = nil
                }
                return
            }

            let maxDownwardGrowth = max(0, currentFrame.minY - screenFrame.minY)
            let desiredIncrease = delta + 20
            let actualIncrease = min(desiredIncrease, maxDownwardGrowth)

            guard actualIncrease > 1 else {
                if forceFinalize {
                    self.pendingWindowAdjustment = nil
                }
                return
            }

            var expandedFrame = currentFrame
            expandedFrame.origin.y -= actualIncrease
            expandedFrame.size.height += actualIncrease
            window.setFrame(expandedFrame, display: true, animate: true)
            self.pendingWindowAdjustment = nil

        case .shrink:
            let slack = scrollViewportHeight - scrollContentHeight
            guard slack > 12 else {
                if forceFinalize {
                    self.pendingWindowAdjustment = nil
                }
                return
            }

            let minimumHeight = max(window.minSize.height, 570)
            let maxShrink = max(0, currentFrame.height - minimumHeight)
            let desiredDecrease = slack - 8
            let actualDecrease = min(desiredDecrease, maxShrink)

            guard actualDecrease > 1 else {
                if forceFinalize {
                    self.pendingWindowAdjustment = nil
                }
                return
            }

            var reducedFrame = currentFrame
            reducedFrame.origin.y += actualDecrease
            reducedFrame.size.height -= actualDecrease
            reducedFrame.origin.y = max(reducedFrame.origin.y, screenFrame.minY)
            window.setFrame(reducedFrame, display: true, animate: true)
            self.pendingWindowAdjustment = nil
        }
    }

    private var localAccountNameBinding: Binding<String> {
        Binding(
            get: { model.writeOptions.customizationProfile.localAccountName ?? "" },
            set: {
                model.writeOptions.customizationProfile.localAccountName = $0.isEmpty ? nil : $0
                model.refreshPlanForSelectionChange()
            }
        )
    }

    private var skipPrivacyBinding: Binding<Bool> {
        Binding(
            get: { model.writeOptions.customizationProfile.disableDataCollection },
            set: {
                model.writeOptions.customizationProfile.disableDataCollection = $0
                model.refreshPlanForSelectionChange()
            }
        )
    }

    private var bypassRequirementsBinding: Binding<Bool> {
        Binding(
            get: { model.writeOptions.customizationProfile.bypassSecureBootTPMRAMChecks },
            set: {
                model.writeOptions.customizationProfile.bypassSecureBootTPMRAMChecks = $0
                model.refreshPlanForSelectionChange()
            }
        )
    }

    private var bypassOnlineAccountBinding: Binding<Bool> {
        Binding(
            get: { model.writeOptions.customizationProfile.bypassOnlineAccountRequirement },
            set: {
                model.writeOptions.customizationProfile.bypassOnlineAccountRequirement = $0
                model.refreshPlanForSelectionChange()
            }
        )
    }

    private var duplicateLocaleBinding: Binding<Bool> {
        Binding(
            get: { model.writeOptions.customizationProfile.duplicateHostLocale },
            set: {
                model.writeOptions.customizationProfile.duplicateHostLocale = $0
                model.refreshPlanForSelectionChange()
            }
        )
    }

    private var disableBitLockerBinding: Binding<Bool> {
        Binding(
            get: { model.writeOptions.customizationProfile.disableBitLocker },
            set: {
                model.writeOptions.customizationProfile.disableBitLocker = $0
                model.refreshPlanForSelectionChange()
            }
        )
    }

    private var useMicrosoft2023BootloadersBinding: Binding<Bool> {
        Binding(
            get: { model.writeOptions.customizationProfile.useMicrosoft2023Bootloaders },
            set: {
                model.writeOptions.customizationProfile.useMicrosoft2023Bootloaders = $0
                model.refreshPlanForSelectionChange()
            }
        )
    }

    private var persistenceEnabledBinding: Binding<Bool> {
        Binding(
            get: { model.writeOptions.enableLinuxPersistence },
            set: {
                model.writeOptions.enableLinuxPersistence = $0
                model.refreshPlanForSelectionChange()
            }
        )
    }

    private var persistenceSizeBinding: Binding<Int> {
        Binding(
            get: { model.writeOptions.linuxPersistenceSizeMiB },
            set: {
                model.writeOptions.linuxPersistenceSizeMiB = $0
                model.refreshPlanForSelectionChange()
            }
        )
    }

    private var localSourceControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Button {
                    chooseSourceImage()
                } label: {
                    Label(model.selectedImageURL == nil ? "Choose Image" : "Change Image", systemImage: "doc.badge.plus")
                }

                if let selectedImageURL = model.selectedImageURL {
                    Text(selectedImageURL.lastPathComponent)
                        .font(.footnote.monospaced())
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }

                Spacer(minLength: 0)

                Button {
                    Task {
                        await model.setSourceMode(.downloadWindows)
                    }
                } label: {
                    Label("Download Windows", systemImage: "arrow.down.circle")
                }
                .disabled(model.isBusy)

                Button {
                    Task {
                        await model.setSourceMode(.bundledFreeDOS)
                    }
                } label: {
                    Label(model.sourceMode == .bundledFreeDOS ? "Using FreeDOS" : "Use FreeDOS", systemImage: "terminal")
                }
                .disabled(model.isBusy || model.sourceMode == .bundledFreeDOS)
            }
            .controlSize(.small)

            if model.sourceMode == .bundledFreeDOS {
                Text("Bundled FreeDOS boot files are selected for this USB.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func chooseSourceImage() {
        Task { @MainActor in
            let allowedTypes = supportedImageTypes.isEmpty ? [UTType.data] : supportedImageTypes
            guard let url = openPanelService.chooseFile(
                title: "Choose Source Image",
                allowedContentTypes: allowedTypes
            ) else {
                return
            }

            await model.setSelectedImage(url)
        }
    }

    private func chooseBootAssetsSource() {
        Task { @MainActor in
            guard let url = openPanelService.chooseBootAssetsSource(
                title: "Choose Boot Assets Source",
                allowedContentTypes: bootAssetsTypes
            ) else {
                return
            }

            await model.setBootAssetsSource(url)
        }
    }

    private var downloadSourceControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Download Family", selection: $model.selectedDownloadFamily) {
                ForEach(DownloadCatalogFamily.allCases) { family in
                    Text(family.label).tag(family)
                }
            }
            .pickerStyle(.segmented)

            HStack(spacing: 12) {
                Button {
                    Task {
                        await model.refreshDownloadCatalog()
                    }
                } label: {
                    Label("Refresh Catalog", systemImage: "arrow.clockwise")
                }
                .disabled(model.isBusy)

                Button {
                    chooseDownloadDestination()
                } label: {
                    Label("Download ISO", systemImage: "arrow.down.circle")
                }
                .disabled(!model.canDownloadWindows)
            }
            .controlSize(.small)

            if model.downloadCatalog.isEmpty {
                warningLabel("Load the official catalog to choose a product, release, language, and architecture.")
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Product", selection: Binding(
                        get: { model.selectedDownloadProductID ?? "" },
                        set: { model.selectedDownloadProductID = $0 }
                    )) {
                        ForEach(model.visibleDownloadCatalog) { product in
                            Text(product.title).tag(product.id)
                        }
                    }

                    Picker("Release", selection: Binding(
                        get: { model.selectedDownloadReleaseID ?? "" },
                        set: { model.selectedDownloadReleaseID = $0 }
                    )) {
                        ForEach(model.selectedDownloadProduct?.releases ?? []) { release in
                            Text(release.title).tag(release.id)
                        }
                    }

                    Picker("Edition", selection: Binding(
                        get: { model.selectedDownloadEditionID ?? "" },
                        set: { model.selectedDownloadEditionID = $0 }
                    )) {
                        ForEach(model.selectedDownloadRelease?.editions ?? []) { edition in
                            Text(edition.title).tag(edition.id)
                        }
                    }

                    Picker("Language", selection: Binding(
                        get: { model.selectedDownloadLanguageID ?? "" },
                        set: { model.selectedDownloadLanguageID = $0 }
                    )) {
                        ForEach(model.downloadLanguages) { language in
                            Text(language.displayName).tag(language.id)
                        }
                    }
                    .disabled(model.downloadLanguages.isEmpty)

                    Picker("Architecture", selection: $model.selectedDownloadArchitecture) {
                        ForEach(model.downloadLinkOptions.map(\.architecture), id: \.self) { architecture in
                            Text(architecture.label).tag(architecture)
                        }
                    }
                    .disabled(model.downloadLinkOptions.isEmpty)
                }
            }
        }
    }

    private func chooseCaptureDestination(format: DriveCaptureFormat) {
        guard let disk = model.selectedDisk else {
            return
        }

        let sanitizedName = disk.displayName
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        let suggestedName = "\(sanitizedName)-\(Date.now.formatted(.iso8601.year().month().day()))"

        guard let destinationURL = savePanelService.chooseDestination(
            title: "Capture \(disk.displayName)",
            suggestedName: suggestedName,
            allowedExtensions: [format.defaultExtension]
        ) else {
            return
        }

        Task {
            await model.captureSelectedDisk(to: destinationURL, format: format)
        }
    }

    private func chooseDownloadDestination() {
        guard let link = model.selectedDownloadLink else {
            return
        }

        guard let destinationURL = savePanelService.chooseDestination(
            title: "Download Official Image",
            suggestedName: link.filename,
            allowedExtensions: ["iso"]
        ) else {
            return
        }

        Task {
            await model.downloadSelectedWindows(to: destinationURL)
        }
    }
}
