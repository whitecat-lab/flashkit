import Foundation
import OSLog

struct ImageClassifier {
    private let registry: VendorProfileRegistry
    private let logger = Logger(subsystem: "FlashKit", category: "ImageClassification")

    init(registry: VendorProfileRegistry = VendorProfileRegistry()) {
        self.registry = registry
    }

    func classify(_ context: ImageClassificationContext) -> ImageClassificationResult {
        let imageKind = context.imageKind
        var warnings = context.probe.ambiguityWarnings
        var evidence: [String] = []

        let matches = registry.profiles.compactMap { profile in
            profile.match(in: context)
        }

        let matchedProfile: VendorProfileMatch?
        let hasAmbiguousVendorMatch: Bool
        if matches.count <= 1 {
            matchedProfile = matches.first
            hasAmbiguousVendorMatch = false
        } else {
            let sorted = matches.sorted { lhs, rhs in
                if lhs.confidence == rhs.confidence {
                    return lhs.vendorID.rawValue < rhs.vendorID.rawValue
                }
                return lhs.confidence > rhs.confidence
            }
            let top = sorted[0]
            let runnerUp = sorted[1]

            if abs(top.confidence - runnerUp.confidence) < 0.08 {
                matchedProfile = nil
                hasAmbiguousVendorMatch = true
                warnings.append("Multiple vendor profiles matched with similar confidence (\(top.vendorID.displayName) and \(runnerUp.vendorID.displayName)). Expert review is required.")
                evidence.append("ambiguous-vendor-match")
            } else {
                matchedProfile = top
                hasAmbiguousVendorMatch = false
            }
        }

        if let matchedProfile {
            warnings.append(contentsOf: matchedProfile.warnings)
            evidence.append(contentsOf: matchedProfile.evidence)
        }

        let recommendedWriteStrategy: RecommendedWriteStrategy
        let safetyPolicy: ImageSafetyPolicy
        let requiresExpertOverride: Bool
        let confidence: Double

        if let matchedProfile {
            recommendedWriteStrategy = matchedProfile.recommendedWriteStrategy
            safetyPolicy = matchedProfile.safetyPolicy
            requiresExpertOverride = matchedProfile.requiresExpertOverride
            confidence = matchedProfile.confidence
        } else if hasAmbiguousVendorMatch {
            recommendedWriteStrategy = .manualReview
            safetyPolicy = .requireExpertOverride
            requiresExpertOverride = true
            confidence = 0.45
        } else {
            recommendedWriteStrategy = defaultRecommendation(for: imageKind)
            safetyPolicy = defaultSafetyPolicy(for: imageKind, warnings: warnings)
            requiresExpertOverride = safetyPolicy == .requireExpertOverride
            confidence = defaultConfidence(for: imageKind, warnings: warnings)
        }

        let result = ImageClassificationResult(
            imageKind: imageKind,
            matchedProfile: matchedProfile,
            confidence: confidence,
            warnings: deduplicated(warnings),
            recommendedWriteStrategy: recommendedWriteStrategy,
            requiresExpertOverride: requiresExpertOverride,
            safetyPolicy: safetyPolicy,
            evidence: deduplicated(evidence)
        )

        logger.info(
            "classification image=\(context.sourceURL.lastPathComponent, privacy: .public) kind=\(result.imageKind.rawValue, privacy: .public) vendor=\(result.matchedVendorProfile?.rawValue ?? "none", privacy: .public) confidence=\(String(format: "%.2f", result.confidence), privacy: .public) safety=\(result.safetyPolicy.rawValue, privacy: .public) strategy=\(result.recommendedWriteStrategy.rawValue, privacy: .public) warnings=\(result.warnings.joined(separator: " | "), privacy: .public)"
        )

        return result
    }

    private func defaultRecommendation(for imageKind: ClassifiedImageKind) -> RecommendedWriteStrategy {
        switch imageKind {
        case .plainISO:
            return .extractAndRebuild
        case .hybridISO:
            return .preserveHybridDirectWrite
        case .rawDiskImage, .compressedRawDiskImage:
            return .rawDiskWrite
        case .unknownAmbiguous:
            return .manualReview
        }
    }

    private func defaultSafetyPolicy(for imageKind: ClassifiedImageKind, warnings: [String]) -> ImageSafetyPolicy {
        if imageKind == .unknownAmbiguous {
            return .requireExpertOverride
        }

        return warnings.isEmpty ? .safeToProceed : .proceedWithWarning
    }

    private func defaultConfidence(for imageKind: ClassifiedImageKind, warnings: [String]) -> Double {
        switch imageKind {
        case .plainISO:
            return warnings.isEmpty ? 0.82 : 0.68
        case .hybridISO:
            return warnings.isEmpty ? 0.88 : 0.72
        case .rawDiskImage:
            return warnings.isEmpty ? 0.84 : 0.70
        case .compressedRawDiskImage:
            return warnings.isEmpty ? 0.80 : 0.66
        case .unknownAmbiguous:
            return 0.35
        }
    }

    private func deduplicated(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}
