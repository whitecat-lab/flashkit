import Foundation

struct VendorValidationOutcome: Sendable {
    let checks: [MediaValidationCheck]
    let warnings: [String]
    let notes: [String]
    let structurallyPlausibleButNotGuaranteedBootable: Bool
}

protocol VendorMediaValidator: Sendable {
    var id: VendorProfileID { get }

    func validate(in context: MediaValidationContext) async -> VendorValidationOutcome
}
