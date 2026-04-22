import Foundation

enum PrivilegedHelperAvailability: Equatable, Sendable {
    case available
    case unavailable(String)

    var isAvailable: Bool {
        if case .available = self {
            return true
        }
        return false
    }

    var bannerMessage: String? {
        switch self {
        case .available:
            return nil
        case let .unavailable(message):
            return message
        }
    }
}

struct PrivilegedHelperStatusService {
    private let helperClient: any PrivilegedOperationClient

    init(helperClient: any PrivilegedOperationClient = PrivilegedHelperClient()) {
        self.helperClient = helperClient
    }

    func availability() async -> PrivilegedHelperAvailability {
        do {
            _ = try await helperClient.runSubprocess(
                executable: "/usr/bin/true",
                arguments: [],
                currentDirectory: nil,
                progressParser: .none,
                expectedTotalBytes: nil,
                phase: "Checking helper",
                message: "Checking privileged helper availability.",
                eventHandler: nil
            )
            return .available
        } catch let error as PrivilegedHelperClientError {
            switch error {
            case .helperUnavailable:
                return .unavailable("Privileged helper not installed. Install it for smoother writes and better progress reporting. FlashKit can still use the macOS administrator password prompt when needed.")
            case .protocolMismatch:
                return .unavailable("Privileged helper needs reinstalling for this build. FlashKit can still use the macOS administrator password prompt when needed.")
            case .invalidResponse, .remoteFailure:
                return .unavailable(error.localizedDescription)
            }
        } catch {
            return .unavailable(error.localizedDescription)
        }
    }
}
