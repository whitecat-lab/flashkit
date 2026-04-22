import Foundation

struct OpenWrtProfile: VendorImageProfile {
    let id: VendorProfileID = .openWrt
    let acceptedImageKinds: Set<ClassifiedImageKind> = [.rawDiskImage, .compressedRawDiskImage]

    func match(in context: ImageClassificationContext) -> VendorProfileMatch? {
        let filenameHit = context.filenameContainsAny(["openwrt"])
        let volumeHit = context.volumeContainsAny(["openwrt"])
        let pathHit = context.pathContainsAny(["openwrt"])

        guard filenameHit || volumeHit || pathHit else {
            return nil
        }

        let filename = context.normalizedFilename
        let likelyCombinedX86 = filename.contains("combined")
            || filename.contains("combined-efi")
            || filename.contains("ext4-combined")
            || filename.contains("x86")
            || filename.contains("efi")
        let likelyFirmwareArtifact = filename.contains("sysupgrade")
            || filename.contains("factory")
            || filename.contains("initramfs")
            || filename.contains("kernel")
            || filename.contains("ubinized")
            || filename.contains("trx")
            || filename.contains(".bin")
            || filename.contains(".itb")

        var confidence = 0.60
        var evidence: [String] = []
        if filenameHit {
            confidence += 0.15
            evidence.append("filename")
        }
        if volumeHit {
            confidence += 0.05
            evidence.append("volume-name")
        }
        if pathHit {
            confidence += 0.05
            evidence.append("layout")
        }
        if likelyCombinedX86 {
            confidence += 0.12
            evidence.append("combined-image")
        }

        if likelyFirmwareArtifact && !likelyCombinedX86 {
            return VendorProfileMatch(
                vendorID: id,
                variant: "device-firmware-artifact",
                confidence: min(confidence, 0.96),
                warnings: ["This looks like a device-specific OpenWrt firmware artifact rather than a generic USB-bootable disk image."],
                recommendedWriteStrategy: .rejectLikelyWrongImage,
                requiresExpertOverride: false,
                safetyPolicy: .rejectLikelyWrongImage,
                evidence: evidence + ["firmware-artifact"]
            )
        }

        switch context.imageKind {
        case .rawDiskImage, .compressedRawDiskImage:
            let safety: ImageSafetyPolicy = likelyCombinedX86 ? .safeToProceed : .proceedWithWarning
            let warnings = likelyCombinedX86
                ? [] : ["OpenWrt was detected, but the backend could not confirm a clearly generic x86-style combined image. Review the target before writing."]
            return VendorProfileMatch(
                vendorID: id,
                variant: likelyCombinedX86 ? "x86-combined-image" : "generic-raw-image",
                confidence: min(confidence, 0.98),
                warnings: warnings,
                recommendedWriteStrategy: .rawDiskWrite,
                requiresExpertOverride: false,
                safetyPolicy: safety,
                evidence: evidence
            )
        case .plainISO, .hybridISO:
            return VendorProfileMatch(
                vendorID: id,
                variant: "installer-iso",
                confidence: min(confidence - 0.10, 0.90),
                warnings: ["OpenWrt is more commonly distributed as raw disk images for USB boot. This ISO-like artifact should be reviewed carefully."],
                recommendedWriteStrategy: .manualReview,
                requiresExpertOverride: true,
                safetyPolicy: .requireExpertOverride,
                evidence: evidence + ["unexpected-iso"]
            )
        case .unknownAmbiguous:
            return VendorProfileMatch(
                vendorID: id,
                variant: "ambiguous",
                confidence: min(confidence - 0.15, 0.85),
                warnings: ["OpenWrt was detected, but the backend could not confirm a safe generic USB image container."],
                recommendedWriteStrategy: .manualReview,
                requiresExpertOverride: true,
                safetyPolicy: .requireExpertOverride,
                evidence: evidence + ["ambiguous-container"]
            )
        }
    }
}
