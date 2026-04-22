import Foundation

struct ProxmoxMediaValidator: VendorMediaValidator {
    let id: VendorProfileID = .proxmoxVE

    func validate(in context: MediaValidationContext) async -> VendorValidationOutcome {
        let roots = context.snapshot.mountedRoots
        var checks: [MediaValidationCheck] = []
        var warnings: [String] = []
        var notes = ["Detected Proxmox VE media is being validated as hybrid installer media."]
        var plausibleOnly = false

        if roots.isEmpty {
            warnings.append("The written Proxmox VE media exposes readable partitions, but this Mac did not mount its installer filesystems for deeper inspection.")
            checks.append(
                MediaValidationCheck(
                    identifier: "vendor-proxmox-installer-structure",
                    title: "Proxmox installer structure",
                    status: .warning,
                    detail: "No mounted Proxmox installer filesystem was available for a deeper structural check."
                )
            )
            plausibleOnly = true
            return VendorValidationOutcome(checks: checks, warnings: warnings, notes: notes, structurallyPlausibleButNotGuaranteedBootable: plausibleOnly)
        }

        let efiPaths = [
            "efi/boot/bootx64.efi",
            "efi/boot/grubx64.efi",
            "efi/proxmox/grubx64.efi",
        ]
        let bootConfigPaths = [
            "boot/grub/grub.cfg",
            "grub/grub.cfg",
            "isolinux/isolinux.cfg",
            "isolinux/isolinux.bin",
            "pve-installer",
        ]

        if containsAny(of: efiPaths, in: roots) {
            checks.append(.init(identifier: "vendor-proxmox-efi", title: "Proxmox EFI boot files", status: .passed, detail: "Found Proxmox-compatible EFI boot artifacts."))
        } else {
            checks.append(.init(identifier: "vendor-proxmox-efi", title: "Proxmox EFI boot files", status: .failed, detail: "Missing the expected Proxmox EFI boot artifacts."))
        }

        if containsAny(of: bootConfigPaths, in: roots) {
            checks.append(.init(identifier: "vendor-proxmox-config", title: "Proxmox installer config", status: .passed, detail: "Found Proxmox installer boot configuration markers."))
        } else {
            checks.append(.init(identifier: "vendor-proxmox-config", title: "Proxmox installer config", status: .failed, detail: "Missing the expected Proxmox installer boot configuration markers."))
        }

        if context.executionMetadata?.recommendedWriteStrategy == .preserveHybridDirectWrite {
            notes.append("The backend preserved the original hybrid installer layout for Proxmox VE.")
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
