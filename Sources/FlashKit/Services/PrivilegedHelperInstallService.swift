import FlashKitHelperProtocol
import Foundation

enum PrivilegedHelperInstallServiceError: LocalizedError {
    case bundledHelperMissing
    case bundledLaunchDaemonMissing

    var errorDescription: String? {
        switch self {
        case .bundledHelperMissing:
            return "This FlashKit build does not contain the bundled privileged helper."
        case .bundledLaunchDaemonMissing:
            return "This FlashKit build does not contain the bundled privileged helper launchd plist."
        }
    }
}

struct PrivilegedHelperInstallService {
    private let privilegeService = AppleScriptPrivilegeService()

    func installBundledHelper() async throws {
        let bundle = Bundle.main.bundleURL
        let bundledHelper = bundle
            .appendingPathComponent("Contents/Library/PrivilegedHelperTools", isDirectory: true)
            .appendingPathComponent(PrivilegedHelperConstants.machServiceName)
        let bundledLaunchDaemon = bundle
            .appendingPathComponent("Contents/Library/LaunchDaemons", isDirectory: true)
            .appendingPathComponent("\(PrivilegedHelperConstants.machServiceName).plist")

        guard FileManager.default.fileExists(atPath: bundledHelper.path()) else {
            throw PrivilegedHelperInstallServiceError.bundledHelperMissing
        }

        guard FileManager.default.fileExists(atPath: bundledLaunchDaemon.path()) else {
            throw PrivilegedHelperInstallServiceError.bundledLaunchDaemonMissing
        }

        let destinationHelper = "/Library/PrivilegedHelperTools/\(PrivilegedHelperConstants.machServiceName)"
        let destinationLaunchDaemon = "/Library/LaunchDaemons/\(PrivilegedHelperConstants.machServiceName).plist"
        let launchdService = "system/\(PrivilegedHelperConstants.machServiceName)"

        let installCommand = """
        set -euo pipefail
        launchctl bootout system \(destinationLaunchDaemon.shellQuoted) >/dev/null 2>&1 || true
        install -d -m 755 /Library/PrivilegedHelperTools /Library/LaunchDaemons
        install -m 755 \(bundledHelper.path().shellQuoted) \(destinationHelper.shellQuoted)
        install -m 644 \(bundledLaunchDaemon.path().shellQuoted) \(destinationLaunchDaemon.shellQuoted)
        chown root:wheel \(destinationHelper.shellQuoted) \(destinationLaunchDaemon.shellQuoted)
        launchctl bootstrap system \(destinationLaunchDaemon.shellQuoted)
        launchctl kickstart -k \(launchdService.shellQuoted) >/dev/null 2>&1 || true
        """

        _ = try await privilegeService.run(shellCommand: installCommand)
    }
}
