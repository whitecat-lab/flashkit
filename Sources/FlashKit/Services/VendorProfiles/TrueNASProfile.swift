import Foundation

struct TrueNASProfile: VendorImageProfile {
    let id: VendorProfileID = .trueNAS
    let acceptedImageKinds: Set<ClassifiedImageKind> = [.plainISO, .hybridISO, .rawDiskImage, .compressedRawDiskImage]

    func match(in context: ImageClassificationContext) -> VendorProfileMatch? {
        let filenameHit = context.filenameContainsAny(["truenas", "freenas"])
        let volumeHit = context.volumeContainsAny(["truenas", "freenas"])
        let loaderHit = context.pathEndsWithAny(["boot/loader.efi", "efi/boot/loader.efi", "boot/defaults/loader.conf"])

        guard filenameHit || volumeHit || loaderHit else {
            return nil
        }

        var confidence = 0.58
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
        if loaderHit {
            confidence += 0.15
            evidence.append("loader-artifacts")
        }

        let strategy: RecommendedWriteStrategy
        let safety: ImageSafetyPolicy
        let requiresExpertOverride: Bool
        let variant: String

        switch context.imageKind {
        case .plainISO, .hybridISO:
            strategy = .extractAndRebuild
            safety = .safeToProceed
            requiresExpertOverride = false
            variant = "installer-iso"
        case .rawDiskImage, .compressedRawDiskImage:
            strategy = .rawDiskWrite
            safety = .proceedWithWarning
            requiresExpertOverride = false
            variant = "disk-image"
            warnings.append("TrueNAS media was classified as a disk image rather than a plain installer ISO. The backend recommends treating it as raw media.")
        case .unknownAmbiguous where loaderHit:
            strategy = .extractAndRebuild
            safety = .proceedWithWarning
            requiresExpertOverride = false
            variant = "extracted-installer-layout"
            warnings.append("TrueNAS loader artifacts were detected from an extracted source layout, so the backend recommends an installer rebuild path.")
        case .unknownAmbiguous:
            strategy = .manualReview
            safety = .requireExpertOverride
            requiresExpertOverride = true
            variant = "ambiguous"
            warnings.append("The file looks TrueNAS-related, but the backend could not classify the image container cleanly.")
        }

        return VendorProfileMatch(
            vendorID: id,
            variant: variant,
            confidence: min(confidence, 0.97),
            warnings: warnings,
            recommendedWriteStrategy: strategy,
            requiresExpertOverride: requiresExpertOverride,
            safetyPolicy: safety,
            evidence: evidence
        )
    }
}
