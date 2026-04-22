import Foundation

struct ExternalDisk: Identifiable, Hashable, Sendable {
    let identifier: String
    let deviceNode: String
    let mediaName: String
    let volumeName: String?
    let size: Int64
    let busProtocol: String?
    let removable: Bool
    let ejectable: Bool
    let writable: Bool

    var id: String { identifier }

    var displayName: String {
        if let volumeName, !volumeName.isEmpty {
            return volumeName
        }

        if !mediaName.isEmpty {
            return mediaName
        }

        return identifier
    }

    var sizeDescription: String {
        ByteCountFormatter.string(fromByteCount: size, countStyle: .binary)
    }

    var detailLine: String {
        [busProtocol, sizeDescription, deviceNode]
            .compactMap { value in
                guard let value, !value.isEmpty else { return nil }
                return value
            }
            .joined(separator: " • ")
    }
}
