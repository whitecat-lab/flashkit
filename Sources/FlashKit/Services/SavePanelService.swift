import AppKit
import Foundation
import UniformTypeIdentifiers

struct SavePanelService {
    @MainActor
    func chooseDestination(
        title: String,
        suggestedName: String,
        allowedExtensions: [String]
    ) -> URL? {
        let panel = NSSavePanel()
        panel.title = title
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.allowedContentTypes = allowedExtensions.compactMap { UTType(filenameExtension: $0) }
        return panel.runModal() == .OK ? panel.url : nil
    }
}
