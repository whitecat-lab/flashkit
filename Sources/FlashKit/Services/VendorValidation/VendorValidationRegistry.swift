import Foundation

struct VendorValidationRegistry: Sendable {
    let validators: [any VendorMediaValidator]

    init(validators: [any VendorMediaValidator] = [
        ProxmoxMediaValidator(),
        TrueNASMediaValidator(),
        OpenWrtMediaValidator(),
        OPNsenseMediaValidator(),
        PfSenseMediaValidator(),
    ]) {
        self.validators = validators
    }

    func validator(for id: VendorProfileID?) -> (any VendorMediaValidator)? {
        guard let id else {
            return nil
        }

        return validators.first { $0.id == id }
    }
}
