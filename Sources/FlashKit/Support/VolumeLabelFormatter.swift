import Foundation

enum VolumeLabelFormatter {
    static let fallbackLabel = "USBMEDIA"
    static let legacyDefaultLabel = "WINUSB"

    static func sanitizedFATLabel(_ input: String) -> String {
        let uppercase = input.uppercased()
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_")
        let scalars = uppercase.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? Character(scalar) : "_"
        }

        let trimmed = String(scalars)
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        let shortened = String(trimmed.prefix(11))

        if shortened.isEmpty {
            return fallbackLabel
        }

        return shortened
    }

    static func sanitizedVolumeName(_ input: String, filesystem: FilesystemType) -> String {
        switch filesystem {
        case .fat, .fat32, .ntfs:
            return sanitizedFATLabel(input)
        case .exfat, .udf, .ext2, .ext3, .ext4:
            let sanitized = input
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: ":", with: "_")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return sanitized.isEmpty ? fallbackLabel : String(sanitized.prefix(32))
        }
    }
}
