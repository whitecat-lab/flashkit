import Foundation

struct OPNsenseMediaValidator: VendorMediaValidator {
    let id: VendorProfileID = .opnSense

    func validate(in context: MediaValidationContext) async -> VendorValidationOutcome {
        validateBSDMemstickVendor(
            vendorName: "OPNsense",
            context: context
        )
    }

    private func validateBSDMemstickVendor(
        vendorName: String,
        context: MediaValidationContext
    ) -> VendorValidationOutcome {
        let roots = context.snapshot.mountedRoots
        let variant = context.sourceProfile.classification?.matchedProfile?.variant
        var checks: [MediaValidationCheck] = []
        var warnings: [String] = []
        var notes = ["Detected \(vendorName) media is being validated as memstick/install media."]
        var plausibleOnly = false

        if let variant {
            notes.append("\(vendorName) variant: \(variant).")
        }

        if roots.isEmpty {
            checks.append(
                .init(
                    identifier: "vendor-opnsense-memstick",
                    title: "\(vendorName) memstick structure",
                    status: .warning,
                    detail: "No mounted \(vendorName) filesystem was available for deeper inspection."
                )
            )
            warnings.append("The written \(vendorName) memstick image exposed a partition layout, but this Mac could not mount its installer filesystems for deeper validation.")
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
            checks.append(.init(identifier: "vendor-opnsense-boot", title: "\(vendorName) boot artifacts", status: .passed, detail: "Found \(vendorName) memstick boot artifacts."))
        } else {
            checks.append(.init(identifier: "vendor-opnsense-boot", title: "\(vendorName) boot artifacts", status: .failed, detail: "Missing the expected \(vendorName) memstick boot artifacts."))
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
