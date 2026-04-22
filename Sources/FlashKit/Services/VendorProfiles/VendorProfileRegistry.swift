import Foundation

struct VendorProfileRegistry {
    let profiles: [any VendorImageProfile]

    init(profiles: [any VendorImageProfile] = [
        ProxmoxProfile(),
        TrueNASProfile(),
        OpenWrtProfile(),
        OPNsenseProfile(),
        PfSenseProfile(),
    ]) {
        self.profiles = profiles
    }
}
