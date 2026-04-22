import Foundation

struct ProxmoxProfile: VendorImageProfile {
    let id: VendorProfileID = .proxmoxVE
    let acceptedImageKinds: Set<ClassifiedImageKind> = [.plainISO, .hybridISO]

    func match(in context: ImageClassificationContext) -> VendorProfileMatch? {
        let filenameHit = context.filenameContainsAny(["proxmox", "pve"])
        let volumeHit = context.volumeContainsAny(["proxmox", "pve"])
        let pathHit = context.pathContainsAny(["proxmox", "/pve", "pve-"])

        guard filenameHit || volumeHit || pathHit else {
            return nil
        }

        var confidence = 0.55
        var evidence: [String] = []
        var warnings: [String] = []

        if filenameHit {
            confidence += 0.15
            evidence.append("filename")
        }
        if volumeHit {
            confidence += 0.10
            evidence.append("volume-name")
        }
        if pathHit {
            confidence += 0.15
            evidence.append("boot-layout")
        }
        if context.imageKind == .hybridISO {
            confidence += 0.10
            evidence.append("hybrid-iso")
        }

        let strategy: RecommendedWriteStrategy
        let safety: ImageSafetyPolicy
        let requiresExpertOverride: Bool

        switch context.imageKind {
        case .hybridISO:
            strategy = .preserveHybridDirectWrite
            safety = .safeToProceed
            requiresExpertOverride = false
        case .plainISO:
            strategy = .extractAndRebuild
            safety = .proceedWithWarning
            requiresExpertOverride = false
            warnings.append("Proxmox VE media is usually hybrid. This image was classified as a plain ISO, so the backend recommends a rebuild-oriented path.")
        case .unknownAmbiguous where pathHit:
            strategy = .extractAndRebuild
            safety = .proceedWithWarning
            requiresExpertOverride = false
            warnings.append("Proxmox VE boot layout markers were detected from an extracted source layout, so the backend recommends a rebuild-oriented path.")
        default:
            strategy = .manualReview
            safety = .requireExpertOverride
            requiresExpertOverride = true
            warnings.append("The file looks Proxmox-related, but the backend did not classify it as a supported installer ISO variant.")
        }

        return VendorProfileMatch(
            vendorID: id,
            variant: context.imageKind == .hybridISO ? "installer-hybrid" : "installer-iso",
            confidence: min(confidence, 0.98),
            warnings: warnings,
            recommendedWriteStrategy: strategy,
            requiresExpertOverride: requiresExpertOverride,
            safetyPolicy: safety,
            evidence: evidence
        )
    }
}
