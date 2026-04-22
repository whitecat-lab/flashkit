import Foundation

struct PfSenseMediaValidator: VendorMediaValidator {
    let id: VendorProfileID = .pfSense

    func validate(in context: MediaValidationContext) async -> VendorValidationOutcome {
        let roots = context.snapshot.mountedRoots
        let variant = context.sourceProfile.classification?.matchedProfile?.variant
        var checks: [MediaValidationCheck] = []
        var warnings: [String] = []
        var notes = ["Detected pfSense media is being validated as memstick/install media."]
        var plausibleOnly = false

        if let variant {
            notes.append("pfSense variant: \(variant).")
        }

        if roots.isEmpty {
            checks.append(
                .init(
                    identifier: "vendor-pfsense-memstick",
                    title: "pfSense memstick structure",
                    status: .warning,
                    detail: "No mounted pfSense filesystem was available for deeper inspection."
                )
            )
            warnings.append("The written pfSense memstick image exposed a partition layout, but this Mac could not mount its installer filesystems for deeper validation.")
            plausibleOnly = true
            return VendorValidationOutcome(checks: checks, warnings: warnings, notes: notes, structurallyPlausibleButNotGuaranteedBootable: plausibleOnly)
        }

        let bootArtifacts = [
            "efi/boot/bootx64.efi",
            "boot/loader.efi",
            "boot/defaults/loader.conf",
            "boot/loader.conf",
        ]

        if containsAny(of: bootArtifacts, in: roots) {
            checks.append(.init(identifier: "vendor-pfsense-boot", title: "pfSense boot artifacts", status: .passed, detail: "Found pfSense memstick boot artifacts."))
        } else {
            checks.append(.init(identifier: "vendor-pfsense-boot", title: "pfSense boot artifacts", status: .failed, detail: "Missing the expected pfSense memstick boot artifacts."))
        }

        return VendorValidationOutcome(checks: checks, warnings: warnings, notes: notes, structurallyPlausibleButNotGuaranteedBootable: plausibleOnly)
    }

    private func containsAny(of relativePaths: [String], in roots: [URL]) -> Bool {
        roots.contains { root in
            relativePaths.contains { relativePath in
                existingURL(in: root, relativePath: relativePath) != nil
            }
        }
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
}
