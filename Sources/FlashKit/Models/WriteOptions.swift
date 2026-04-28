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
    let completedBytes: Int64?
    let totalBytes: Int64?
    let rateBytesPerSecond: Double?
    let details: [String]
    let shouldLogMessage: Bool

    init(
        phase: String,
        message: String,
        fractionCompleted: Double?,
        completedBytes: Int64? = nil,
        totalBytes: Int64? = nil,
        rateBytesPerSecond: Double? = nil,
        details: [String] = [],
        shouldLogMessage: Bool = true
    ) {
        self.phase = phase
        self.message = message
        self.fractionCompleted = fractionCompleted
        self.completedBytes = completedBytes
        self.totalBytes = totalBytes
        self.rateBytesPerSecond = rateBytesPerSecond
        self.details = details
        self.shouldLogMessage = shouldLogMessage
    }
}
