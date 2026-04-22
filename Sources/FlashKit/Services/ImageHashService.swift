import CryptoKit
import Foundation

struct ImageHashService {
    func computeHashes(for fileURL: URL, algorithms: [HashAlgorithm]) async throws -> [HashResult] {
        var results: [HashResult] = []
        for algorithm in algorithms {
            let digest = try hash(fileURL: fileURL, algorithm: algorithm)
            results.append(HashResult(algorithm: algorithm, hexDigest: digest))
        }
        return results
    }

    private func hash(fileURL: URL, algorithm: HashAlgorithm) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        switch algorithm {
        case .md5:
            var hasher = Insecure.MD5()
            try stream(into: &hasher, handle: handle)
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        case .sha1:
            var hasher = Insecure.SHA1()
            try stream(into: &hasher, handle: handle)
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        case .sha256:
            var hasher = SHA256()
            try stream(into: &hasher, handle: handle)
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }
    }

    private func stream<H: HashFunction>(into hasher: inout H, handle: FileHandle) throws {
        while true {
            let data = try handle.read(upToCount: 1024 * 1024) ?? Data()
            if data.isEmpty {
                break
            }

            hasher.update(data: data)
        }
    }
}
