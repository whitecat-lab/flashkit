import Foundation

struct TrueNASMediaValidator: VendorMediaValidator {
    let id: VendorProfileID = .trueNAS

    func validate(in context: MediaValidationContext) async -> VendorValidationOutcome {
        let roots = context.snapshot.mountedRoots
        var checks: [MediaValidationCheck] = []
        var warnings: [String] = []
        var notes = ["Detected TrueNAS media is being validated as installer media."]
        var plausibleOnly = false

        if roots.isEmpty {
            warnings.append("The written TrueNAS media did not expose a mounted installer filesystem on this Mac, so only partition-level structure could be checked.")
            checks.append(
                .init(
                    identifier: "vendor-truenas-structure",
                    title: "TrueNAS installer structure",
                    status: .warning,
                    detail: "No mounted TrueNAS installer filesystem was available for deeper validation."
                )
            )
            plausibleOnly = true
            return VendorValidationOutcome(checks: checks, warnings: warnings, notes: notes, structurallyPlausibleButNotGuaranteedBootable: plausibleOnly)
        }

        let loaderPaths = [
            "boot/loader.efi",
            "efi/boot/loader.efi",
            "efi/boot/bootx64.efi",
        ]
        let configPaths = [
            "boot/defaults/loader.conf",
            "boot/loader.conf",
        ]

        if containsAny(of: loaderPaths, in: roots) {
            checks.append(.init(identifier: "vendor-truenas-loader", title: "TrueNAS loader", status: .passed, detail: "Found TrueNAS loader artifacts."))
        } else {
            checks.append(.init(identifier: "vendor-truenas-loader", title: "TrueNAS loader", status: .failed, detail: "Missing the expected TrueNAS loader artifacts."))
        }

        if containsAny(of: configPaths, in: roots) {
            checks.append(.init(identifier: "vendor-truenas-config", title: "TrueNAS boot config", status: .passed, detail: "Found TrueNAS boot configuration files."))
        } else {
            checks.append(.init(identifier: "vendor-truenas-config", title: "TrueNAS boot config", status: .warning, detail: "No TrueNAS boot configuration file was readable from the mounted installer filesystem."))
            warnings.append("TrueNAS loader artifacts were found, but the boot configuration files were not readable from the mounted installer filesystem.")
            plausibleOnly = true
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
