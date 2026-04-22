import Foundation

struct OPNsenseProfile: VendorImageProfile {
    let id: VendorProfileID = .opnSense
    let acceptedImageKinds: Set<ClassifiedImageKind> = [.rawDiskImage, .compressedRawDiskImage, .plainISO, .hybridISO]

    func match(in context: ImageClassificationContext) -> VendorProfileMatch? {
        let filenameHit = context.filenameContainsAny(["opnsense"])
        let volumeHit = context.volumeContainsAny(["opnsense"])

        guard filenameHit || volumeHit else {
            return nil
        }

        let filename = context.normalizedFilename
        let isMemstick = filename.contains("memstick") || filename.contains("usb")
        let variant: String?
        if filename.contains("serial") {
            variant = "serial"
        } else if filename.contains("vga") {
            variant = "vga"
        } else {
            variant = nil
        }

        var confidence = 0.60
        var evidence: [String] = []
        if filenameHit {
            confidence += 0.15
            evidence.append("filename")
        }
        if volumeHit {
            confidence += 0.10
            evidence.append("volume-name")
        }
        if isMemstick {
            confidence += 0.10
            evidence.append("memstick")
        }
        if variant != nil {
            confidence += 0.05
            evidence.append("video-or-serial-variant")
        }

        switch context.imageKind {
        case .rawDiskImage, .compressedRawDiskImage:
            let warnings = isMemstick ? [] : ["OPNsense was detected, but the filename did not clearly identify a memstick-style image."]
            return VendorProfileMatch(
                vendorID: id,
                variant: variant ?? (isMemstick ? "memstick" : "raw-image"),
                confidence: min(confidence, 0.97),
                warnings: warnings,
                recommendedWriteStrategy: .memstickRawWrite,
                requiresExpertOverride: false,
                safetyPolicy: warnings.isEmpty ? .safeToProceed : .proceedWithWarning,
                evidence: evidence
            )
        case .plainISO, .hybridISO:
            return VendorProfileMatch(
                vendorID: id,
                variant: variant ?? "installer-iso",
                confidence: min(confidence - 0.08, 0.90),
                warnings: ["OPNsense media was detected as an ISO-like image instead of a memstick image. Review whether a raw memstick build would be safer for USB media."],
                recommendedWriteStrategy: .extractAndRebuild,
                requiresExpertOverride: false,
                safetyPolicy: .proceedWithWarning,
                evidence: evidence + ["iso-variant"]
            )
        case .unknownAmbiguous:
            return VendorProfileMatch(
                vendorID: id,
                variant: variant ?? "ambiguous",
                confidence: min(confidence - 0.18, 0.82),
                warnings: ["The file looks OPNsense-related, but the backend could not classify a clean memstick or ISO container."],
                recommendedWriteStrategy: .manualReview,
                requiresExpertOverride: true,
                safetyPolicy: .requireExpertOverride,
                evidence: evidence + ["ambiguous-container"]
            )
        }
    }
}
