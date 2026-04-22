import Foundation

struct OpenWrtMediaValidator: VendorMediaValidator {
    let id: VendorProfileID = .openWrt

    func validate(in context: MediaValidationContext) async -> VendorValidationOutcome {
        let classification = context.sourceProfile.classification
        var checks: [MediaValidationCheck] = []
        var warnings: [String] = []
        var notes = ["Detected OpenWrt media is being validated only for generic USB-suitable disk-image variants."]
        var plausibleOnly = false

        if classification?.safetyPolicy == .rejectLikelyWrongImage {
            checks.append(
                .init(
                    identifier: "vendor-openwrt-variant",
                    title: "OpenWrt image suitability",
                    status: .failed,
                    detail: classification?.warnings.first ?? "This OpenWrt artifact was classified as device-specific firmware, not generic USB-bootable media."
                )
            )
            return VendorValidationOutcome(checks: checks, warnings: warnings, notes: notes, structurallyPlausibleButNotGuaranteedBootable: false)
        }

        if context.snapshot.partitions.isEmpty {
            checks.append(
                .init(
                    identifier: "vendor-openwrt-layout",
                    title: "OpenWrt raw disk layout",
                    status: .warning,
                    detail: "The written OpenWrt image did not expose a readable partition layout on this Mac."
                )
            )
            warnings.append("The accepted OpenWrt image wrote successfully, but this Mac could not confirm a readable raw disk layout afterward.")
            plausibleOnly = true
        } else {
            checks.append(
                .init(
                    identifier: "vendor-openwrt-layout",
                    title: "OpenWrt raw disk layout",
                    status: .passed,
                    detail: "The written OpenWrt image exposed \(context.snapshot.partitions.count) readable partition(s)."
                )
            )
        }

        if let variant = classification?.matchedProfile?.variant {
            notes.append("OpenWrt variant: \(variant).")
        }

        return VendorValidationOutcome(checks: checks, warnings: warnings, notes: notes, structurallyPlausibleButNotGuaranteedBootable: plausibleOnly)
    }
}
