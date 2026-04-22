import Foundation

enum ClassifiedImageKind: String, CaseIterable, Sendable {
    case plainISO = "plain-iso"
    case hybridISO = "hybrid-iso"
    case rawDiskImage = "raw-disk-image"
    case compressedRawDiskImage = "compressed-raw-disk-image"
    case unknownAmbiguous = "unknown-ambiguous"
}

enum VendorProfileID: String, CaseIterable, Sendable {
    case proxmoxVE = "proxmox-ve"
    case trueNAS = "truenas"
    case openWrt = "openwrt"
    case opnSense = "opnsense"
    case pfSense = "pfsense"

    var displayName: String {
        switch self {
        case .proxmoxVE:
            return "Proxmox VE"
        case .trueNAS:
            return "TrueNAS"
        case .openWrt:
            return "OpenWrt"
        case .opnSense:
            return "OPNsense"
        case .pfSense:
            return "pfSense"
        }
    }
}

enum RecommendedWriteStrategy: String, Sendable {
    case preserveHybridDirectWrite = "preserve-hybrid-direct-write"
    case extractAndRebuild = "extract-and-rebuild"
    case rawDiskWrite = "raw-disk-write"
    case memstickRawWrite = "memstick-raw-write"
    case manualReview = "manual-review"
    case rejectLikelyWrongImage = "reject-likely-wrong-image"
}

enum ImageSafetyPolicy: String, Sendable {
    case safeToProceed = "safe-to-proceed"
    case proceedWithWarning = "proceed-with-warning"
    case requireExpertOverride = "require-expert-override"
    case rejectLikelyWrongImage = "reject-likely-wrong-image"
}

struct VendorProfileMatch: Sendable {
    let vendorID: VendorProfileID
    let variant: String?
    let confidence: Double
    let warnings: [String]
    let recommendedWriteStrategy: RecommendedWriteStrategy
    let requiresExpertOverride: Bool
    let safetyPolicy: ImageSafetyPolicy
    let evidence: [String]
}

struct ImageClassificationResult: Sendable {
    let imageKind: ClassifiedImageKind
    let matchedProfile: VendorProfileMatch?
    let confidence: Double
    let warnings: [String]
    let recommendedWriteStrategy: RecommendedWriteStrategy
    let requiresExpertOverride: Bool
    let safetyPolicy: ImageSafetyPolicy
    let evidence: [String]

    var matchedVendorProfile: VendorProfileID? {
        matchedProfile?.vendorID
    }
}

struct ImageBinaryProbe: Sendable {
    let sourceURL: URL
    let fileSize: Int64
    let declaredFormat: SourceImageFormat
    let compression: RawDiskCompression?
    let hasGzipMagic: Bool
    let hasXZMagic: Bool
    let hasISO9660Marker: Bool
    let hasUDFMarker: Bool
    let hasMBRSignature: Bool
    let hasGPTSignature: Bool
    let isoHybridStyle: ISOHybridStyle

    static func synthetic(
        sourceURL: URL,
        fileSize: Int64 = 0,
        declaredFormat: SourceImageFormat = .unknown,
        compression: RawDiskCompression? = nil,
        hasGzipMagic: Bool = false,
        hasXZMagic: Bool = false,
        hasISO9660Marker: Bool = false,
        hasUDFMarker: Bool = false,
        hasMBRSignature: Bool = false,
        hasGPTSignature: Bool = false,
        isoHybridStyle: ISOHybridStyle = .notApplicable
    ) -> ImageBinaryProbe {
        ImageBinaryProbe(
            sourceURL: sourceURL,
            fileSize: fileSize,
            declaredFormat: declaredFormat,
            compression: compression,
            hasGzipMagic: hasGzipMagic,
            hasXZMagic: hasXZMagic,
            hasISO9660Marker: hasISO9660Marker,
            hasUDFMarker: hasUDFMarker,
            hasMBRSignature: hasMBRSignature,
            hasGPTSignature: hasGPTSignature,
            isoHybridStyle: isoHybridStyle
        )
    }

    var imageKind: ClassifiedImageKind {
        if hasISO9660Marker || hasUDFMarker {
            return isoHybridStyle.isHybrid ? .hybridISO : .plainISO
        }

        if compression != nil && (RawDiskImageService.isSupportedRawImage(sourceURL) || hasGzipMagic || hasXZMagic) {
            return .compressedRawDiskImage
        }

        if declaredFormat == .dd || RawDiskImageService.isPlainRawImage(sourceURL) || hasMBRSignature || hasGPTSignature {
            return .rawDiskImage
        }

        return .unknownAmbiguous
    }

    var ambiguityWarnings: [String] {
        var warnings: [String] = []

        if declaredFormat == .iso && !(hasISO9660Marker || hasUDFMarker) {
            warnings.append("The file uses an .iso extension but did not expose ISO9660/UDF markers during backend probing.")
        }

        if compression == .gzip && !hasGzipMagic {
            warnings.append("The filename suggests gzip compression, but the gzip magic header was not detected.")
        }

        if compression == .xz && !hasXZMagic {
            warnings.append("The filename suggests XZ compression, but the XZ magic header was not detected.")
        }

        if RawDiskImageService.isPlainRawImage(sourceURL) && (hasISO9660Marker || hasUDFMarker) {
            warnings.append("The file uses a raw-disk extension but also exposes ISO filesystem markers.")
        }

        if imageKind == .unknownAmbiguous {
            warnings.append("The backend could not classify the image cleanly from its extension and on-disk signatures alone.")
        }

        return warnings
    }
}

struct ImageLayoutHints: Sendable {
    let volumeName: String?
    let relativePaths: Set<String>
    let topLevelNames: Set<String>

    static let empty = ImageLayoutHints(volumeName: nil, relativePaths: [], topLevelNames: [])
}

struct ImageClassificationContext: Sendable {
    let sourceURL: URL
    let probe: ImageBinaryProbe
    let layoutHints: ImageLayoutHints
    let bootArtifactPaths: Set<String>
    let hasEFI: Bool
    let hasBIOS: Bool

    var normalizedFilename: String {
        sourceURL.lastPathComponent.lowercased()
    }

    var normalizedVolumeName: String {
        (layoutHints.volumeName ?? "").lowercased()
    }

    var imageKind: ClassifiedImageKind {
        probe.imageKind
    }

    func filenameContainsAny(_ terms: [String]) -> Bool {
        terms.contains { normalizedFilename.contains($0.lowercased()) }
    }

    func volumeContainsAny(_ terms: [String]) -> Bool {
        let value = normalizedVolumeName
        guard !value.isEmpty else {
            return false
        }

        return terms.contains { value.contains($0.lowercased()) }
    }

    func pathContainsAny(_ terms: [String]) -> Bool {
        let loweredTerms = terms.map { $0.lowercased() }
        return layoutHints.relativePaths.contains { path in
            loweredTerms.contains { path.contains($0) }
        } || bootArtifactPaths.contains { path in
            loweredTerms.contains { path.contains($0) }
        }
    }

    func pathEndsWithAny(_ suffixes: [String]) -> Bool {
        let loweredSuffixes = suffixes.map { $0.lowercased() }
        return layoutHints.relativePaths.contains { path in
            loweredSuffixes.contains { path.hasSuffix($0) }
        } || bootArtifactPaths.contains { path in
            loweredSuffixes.contains { path.hasSuffix($0) }
        }
    }

    func topLevelNameContainsAny(_ terms: [String]) -> Bool {
        let loweredTerms = terms.map { $0.lowercased() }
        return layoutHints.topLevelNames.contains { name in
            loweredTerms.contains { name.contains($0) }
        }
    }
}
