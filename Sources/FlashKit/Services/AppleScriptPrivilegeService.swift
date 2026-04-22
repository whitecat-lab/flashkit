import Foundation

struct AppleScriptPrivilegeService {
    private let runner = ProcessRunner()

    func run(
        shellCommand: String,
        onStart: (@Sendable (Int32) async -> Void)? = nil
    ) async throws -> ProcessResult {
        try await runner.run(
            "/usr/bin/osascript",
            arguments: [
                "-e",
                #"do shell script "\#(shellCommand.appleScriptEscaped)" with administrator privileges"#
            ],
            onStart: onStart
        )
    }
}
