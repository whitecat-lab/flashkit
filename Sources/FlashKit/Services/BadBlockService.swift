import Foundation

enum BadBlockServiceError: LocalizedError {
    case invalidPassCount
    case fileTooSmall(URL)

    var errorDescription: String? {
        switch self {
        case .invalidPassCount:
            return "Bad block validation needs at least one pass."
        case let .fileTooSmall(url):
            return "\(url.lastPathComponent) does not contain enough bytes to validate."
        }
    }
}

struct BadBlockService {
    private let chunkSize = 4 * 1024 * 1024
    private let deviceChunkSize = 64 * 1024 * 1024
    private let privileged = PrivilegedCommandService()
    private let runner = ProcessRunner()

    func runDestructiveTest(on disk: ExternalDisk, passCount: Int) async throws -> BadBlockReport {
        guard passCount > 0 else {
            throw BadBlockServiceError.invalidPassCount
        }

        let rawDevicePath = disk.deviceNode.replacingOccurrences(of: "/dev/disk", with: "/dev/rdisk")
        let chunkBytes = Int64(min(deviceChunkSize, max(chunkSize, Int(disk.size))))
        let writableSpan = disk.size < chunkBytes ? disk.size : (disk.size / chunkBytes) * chunkBytes
        guard writableSpan > 0 else {
            throw BadBlockServiceError.fileTooSmall(URL(fileURLWithPath: rawDevicePath))
        }

        try await privileged.run("/usr/sbin/diskutil", arguments: ["unmountDisk", "force", disk.deviceNode])

        let temporaryDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("FlashKit-BadBlocks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        var bytesWritten: Int64 = 0
        var bytesTested: Int64 = 0
        var badBlockCount = 0
        var suspectedFakeCapacity = false
        var notes: [String] = []

        if writableSpan < disk.size {
            let skipped = disk.size - writableSpan
            notes.append("Validation covered \(ByteCountFormatter.string(fromByteCount: writableSpan, countStyle: .binary)) in fixed-size chunks and skipped the trailing \(ByteCountFormatter.string(fromByteCount: skipped, countStyle: .binary)).")
        }

        for pass in 0..<passCount {
            try Task.checkCancellation()
            var offset: Int64 = 0
            while offset < writableSpan {
                try Task.checkCancellation()
                let length = Int(min(chunkBytes, writableSpan - offset))
                let patternURL = temporaryDirectory.appendingPathComponent("pattern-\(pass)-\(offset).bin")
                let readbackURL = temporaryDirectory.appendingPathComponent("readback-\(pass)-\(offset).bin")
                let pattern = validationPattern(forPass: pass, offset: offset, length: length)
                try pattern.write(to: patternURL, options: .atomic)

                let blockIndex = offset / chunkBytes
                do {
                    try await privileged.run(
                        "/bin/dd",
                        arguments: [
                            "if=\(patternURL.path())",
                            "of=\(rawDevicePath)",
                            "bs=\(chunkBytes)",
                            "seek=\(blockIndex)",
                            "count=1",
                            "conv=sync",
                        ]
                    )
                    bytesWritten += Int64(length)

                    try await privileged.run(
                        "/bin/dd",
                        arguments: [
                            "if=\(rawDevicePath)",
                            "of=\(readbackURL.path())",
                            "bs=\(chunkBytes)",
                            "skip=\(blockIndex)",
                            "count=1",
                        ]
                    )
                } catch {
                    suspectedFakeCapacity = true
                    notes.append("The target stopped responding cleanly at byte offset \(offset).")
                    break
                }

                let readBack = try Data(contentsOf: readbackURL)
                let comparedBytes = min(readBack.count, length)
                bytesTested += Int64(comparedBytes)

                if readBack.count < length {
                    suspectedFakeCapacity = true
                    notes.append("Short read at byte offset \(offset). Expected \(length) bytes, got \(readBack.count).")
                    break
                }

                if readBack.prefix(length) != pattern {
                    badBlockCount += 1
                    notes.append("Mismatch detected at byte offset \(offset) on pass \(pass + 1).")
                }

                offset += Int64(length)
            }
        }

        _ = try? await runner.run("/usr/bin/sync", arguments: [])

        if notes.isEmpty {
            notes.append("Validated \(writableSpan) bytes across \(passCount) pass(es) using \(chunkBytes / 1_048_576) MiB device chunks.")
        }

        return BadBlockReport(
            bytesTested: bytesTested,
            bytesWritten: bytesWritten,
            badBlockCount: badBlockCount,
            suspectedFakeCapacity: suspectedFakeCapacity,
            notes: notes
        )
    }

    func runDestructiveTest(
        onImageAt fileURL: URL,
        expectedCapacity: Int64? = nil,
        passCount: Int
    ) throws -> BadBlockReport {
        guard passCount > 0 else {
            throw BadBlockServiceError.invalidPassCount
        }

        let fileSize = try fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize.map(Int64.init) ?? 0
        let targetSize = expectedCapacity ?? fileSize
        guard targetSize > 0 else {
            throw BadBlockServiceError.fileTooSmall(fileURL)
        }

        let writableSpan = min(fileSize, targetSize)
        guard writableSpan > 0 else {
            throw BadBlockServiceError.fileTooSmall(fileURL)
        }

        let handle = try FileHandle(forUpdating: fileURL)
        defer { try? handle.close() }

        var bytesWritten: Int64 = 0
        var bytesTested: Int64 = 0
        var badBlockCount = 0
        var suspectedFakeCapacity = fileSize > 0 && fileSize < targetSize
        var notes: [String] = []

        if suspectedFakeCapacity {
            notes.append("The target exposed \(targetSize) bytes but only \(fileSize) bytes were writable during validation.")
        }

        for pass in 0..<passCount {
            var offset: Int64 = 0
            while offset < writableSpan {
                let length = Int(min(Int64(chunkSize), writableSpan - offset))
                let pattern = validationPattern(forPass: pass, offset: offset, length: length)

                try handle.seek(toOffset: UInt64(offset))
                try handle.write(contentsOf: pattern)
                bytesWritten += Int64(length)

                try handle.seek(toOffset: UInt64(offset))
                let readBack = try handle.read(upToCount: length) ?? Data()
                bytesTested += Int64(readBack.count)

                if readBack.count < length {
                    suspectedFakeCapacity = true
                    notes.append("Short read at byte offset \(offset). Expected \(length) bytes, got \(readBack.count).")
                    break
                }

                if readBack != pattern {
                    badBlockCount += 1
                    notes.append("Mismatch detected at byte offset \(offset) on pass \(pass + 1).")
                }

                offset += Int64(length)
            }
        }

        if notes.isEmpty {
            notes.append("Validated \(writableSpan) bytes across \(passCount) pass(es) using \(chunkSize / 1_048_576) MiB chunks.")
        }

        return BadBlockReport(
            bytesTested: bytesTested,
            bytesWritten: bytesWritten,
            badBlockCount: badBlockCount,
            suspectedFakeCapacity: suspectedFakeCapacity,
            notes: notes
        )
    }

    func validationPattern(forPass pass: Int, offset: Int64, length: Int) -> Data {
        let seed = UInt8(truncatingIfNeeded: (offset / Int64(chunkSize)) &+ Int64(pass * 37))
        return Data(repeating: seed == 0 ? 0xA5 : seed, count: length)
    }
}
