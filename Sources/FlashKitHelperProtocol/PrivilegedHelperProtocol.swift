import Foundation

public enum PrivilegedHelperConstants {
    public static let machServiceName = "io.flashkit.FlashKit.PrivilegedHelper"
    public static let protocolVersion = 1
}

public enum PrivilegedSubprocessProgressParser: String, Codable, Sendable {
    case none
    case ntfsPopulate
}

public enum PrivilegedWorkerEventKind: String, Codable, Sendable {
    case helperStarted
    case childStarted
    case progress
    case message
    case finished
    case failed
}

public struct PrivilegedTargetExpectation: Codable, Sendable {
    public let expectedDeviceNode: String
    public let expectedWholeDisk: Bool
    public let expectedSizeBytes: Int64?
    public let requireWritable: Bool
    public let requireRemovable: Bool
    public let allowUnsafeTargetsWithExpertOverride: Bool
    public let expertOverrideEnabled: Bool
    public let forceUnmountWholeDisk: Bool

    public init(
        expectedDeviceNode: String,
        expectedWholeDisk: Bool,
        expectedSizeBytes: Int64?,
        requireWritable: Bool,
        requireRemovable: Bool,
        allowUnsafeTargetsWithExpertOverride: Bool,
        expertOverrideEnabled: Bool,
        forceUnmountWholeDisk: Bool
    ) {
        self.expectedDeviceNode = expectedDeviceNode
        self.expectedWholeDisk = expectedWholeDisk
        self.expectedSizeBytes = expectedSizeBytes
        self.requireWritable = requireWritable
        self.requireRemovable = requireRemovable
        self.allowUnsafeTargetsWithExpertOverride = allowUnsafeTargetsWithExpertOverride
        self.expertOverrideEnabled = expertOverrideEnabled
        self.forceUnmountWholeDisk = forceUnmountWholeDisk
    }
}

public struct PrivilegedSubprocessRequest: Codable, Sendable {
    public let executablePath: String
    public let arguments: [String]
    public let currentDirectoryPath: String?
    public let progressParser: PrivilegedSubprocessProgressParser
    public let expectedTotalBytes: Int64?
    public let phase: String
    public let message: String

    public init(
        executablePath: String,
        arguments: [String],
        currentDirectoryPath: String? = nil,
        progressParser: PrivilegedSubprocessProgressParser = .none,
        expectedTotalBytes: Int64? = nil,
        phase: String,
        message: String
    ) {
        self.executablePath = executablePath
        self.arguments = arguments
        self.currentDirectoryPath = currentDirectoryPath
        self.progressParser = progressParser
        self.expectedTotalBytes = expectedTotalBytes
        self.phase = phase
        self.message = message
    }
}

public struct PrivilegedRawWriteRequest: Codable, Sendable {
    public let destinationDeviceNode: String
    public let sourceFilePath: String?
    public let streamExecutablePath: String?
    public let streamArguments: [String]
    public let expectedBytes: Int64?
    public let phase: String
    public let message: String
    public let targetExpectation: PrivilegedTargetExpectation?

    public init(
        destinationDeviceNode: String,
        sourceFilePath: String? = nil,
        streamExecutablePath: String? = nil,
        streamArguments: [String] = [],
        expectedBytes: Int64?,
        phase: String,
        message: String,
        targetExpectation: PrivilegedTargetExpectation?
    ) {
        self.destinationDeviceNode = destinationDeviceNode
        self.sourceFilePath = sourceFilePath
        self.streamExecutablePath = streamExecutablePath
        self.streamArguments = streamArguments
        self.expectedBytes = expectedBytes
        self.phase = phase
        self.message = message
        self.targetExpectation = targetExpectation
    }
}

public struct PrivilegedRawCaptureRequest: Codable, Sendable {
    public let sourceDeviceNode: String
    public let destinationFilePath: String
    public let expectedBytes: Int64
    public let phase: String
    public let message: String
    public let targetExpectation: PrivilegedTargetExpectation?

    public init(
        sourceDeviceNode: String,
        destinationFilePath: String,
        expectedBytes: Int64,
        phase: String,
        message: String,
        targetExpectation: PrivilegedTargetExpectation?
    ) {
        self.sourceDeviceNode = sourceDeviceNode
        self.destinationFilePath = destinationFilePath
        self.expectedBytes = expectedBytes
        self.phase = phase
        self.message = message
        self.targetExpectation = targetExpectation
    }
}

public struct PrivilegedHelperRequest: Codable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case subprocess
        case rawWrite
        case rawCapture
    }

    public let protocolVersion: Int
    public let operationID: String
    public let kind: Kind
    public let subprocess: PrivilegedSubprocessRequest?
    public let rawWrite: PrivilegedRawWriteRequest?
    public let rawCapture: PrivilegedRawCaptureRequest?

    public init(operationID: String, subprocess: PrivilegedSubprocessRequest) {
        protocolVersion = PrivilegedHelperConstants.protocolVersion
        self.operationID = operationID
        kind = .subprocess
        self.subprocess = subprocess
        rawWrite = nil
        rawCapture = nil
    }

    public init(operationID: String, rawWrite: PrivilegedRawWriteRequest) {
        protocolVersion = PrivilegedHelperConstants.protocolVersion
        self.operationID = operationID
        kind = .rawWrite
        subprocess = nil
        self.rawWrite = rawWrite
        rawCapture = nil
    }

    public init(operationID: String, rawCapture: PrivilegedRawCaptureRequest) {
        protocolVersion = PrivilegedHelperConstants.protocolVersion
        self.operationID = operationID
        kind = .rawCapture
        subprocess = nil
        rawWrite = nil
        self.rawCapture = rawCapture
    }
}

public struct PrivilegedHelperResponse: Codable, Sendable {
    public let protocolVersion: Int
    public let helperPID: Int32
    public let childPID: Int32?
    public let bytesTransferred: Int64?
    public let standardOutput: String
    public let standardError: String

    public init(
        helperPID: Int32,
        childPID: Int32? = nil,
        bytesTransferred: Int64? = nil,
        standardOutput: String = "",
        standardError: String = ""
    ) {
        protocolVersion = PrivilegedHelperConstants.protocolVersion
        self.helperPID = helperPID
        self.childPID = childPID
        self.bytesTransferred = bytesTransferred
        self.standardOutput = standardOutput
        self.standardError = standardError
    }
}

public struct PrivilegedWorkerEvent: Codable, Sendable {
    public let protocolVersion: Int
    public let operationID: String
    public let kind: PrivilegedWorkerEventKind
    public let phase: String
    public let helperPID: Int32
    public let childPID: Int32?
    public let command: [String]?
    public let message: String?
    public let bytesCompleted: Int64?
    public let totalBytes: Int64?
    public let rateBytesPerSecond: Double?
    public let exitStatus: Int32?
    public let failureReason: String?

    public init(
        operationID: String,
        kind: PrivilegedWorkerEventKind,
        phase: String,
        helperPID: Int32,
        childPID: Int32? = nil,
        command: [String]? = nil,
        message: String? = nil,
        bytesCompleted: Int64? = nil,
        totalBytes: Int64? = nil,
        rateBytesPerSecond: Double? = nil,
        exitStatus: Int32? = nil,
        failureReason: String? = nil
    ) {
        protocolVersion = PrivilegedHelperConstants.protocolVersion
        self.operationID = operationID
        self.kind = kind
        self.phase = phase
        self.helperPID = helperPID
        self.childPID = childPID
        self.command = command
        self.message = message
        self.bytesCompleted = bytesCompleted
        self.totalBytes = totalBytes
        self.rateBytesPerSecond = rateBytesPerSecond
        self.exitStatus = exitStatus
        self.failureReason = failureReason
    }
}

@objc public protocol FlashKitPrivilegedProgressXPC {
    func publishEvent(_ eventData: Data)
}

@objc public protocol FlashKitPrivilegedHelperXPC {
    func performRequest(_ requestData: Data, withReply reply: @escaping (Data?, String?) -> Void)
    func cancelOperation(_ operationID: String, withReply reply: @escaping (String?) -> Void)
}
