import Foundation

struct WriteOptions: Sendable {
    var ejectWhenFinished = true
    var verifyWithSHA256 = true
    var customizationProfile = CustomizationProfile.none
    var enableLinuxPersistence = false
    var linuxPersistenceSizeMiB = 4_096
    var expertOverrideEnabled = false
}

struct WriteSessionUpdate: Sendable {
    let phase: String
    let message: String
    let fractionCompleted: Double?
    let details: [String]
    let shouldLogMessage: Bool

    init(
        phase: String,
        message: String,
        fractionCompleted: Double?,
        details: [String] = [],
        shouldLogMessage: Bool = true
    ) {
        self.phase = phase
        self.message = message
        self.fractionCompleted = fractionCompleted
        self.details = details
        self.shouldLogMessage = shouldLogMessage
    }
}
