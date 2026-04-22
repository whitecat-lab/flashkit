import FlashKitHelperProtocol
import Foundation

enum UEFINTFSServiceError: LocalizedError {
    case missingImage

    var errorDescription: String? {
        switch self {
        case .missingImage:
            return "The bundled UEFI:NTFS image could not be found."
        }
    }
}

struct UEFINTFSService {
    private let privileged = PrivilegedCommandService()

    func stageHelperPartition(
        _ partition: DiskPartition,
        toolchain: ToolchainStatus,
        eventHandler: PrivilegedWorkerEventHandler? = nil
    ) async throws {
        guard let imagePath = toolchain.path(for: .uefiNTFSImage) else {
            throw UEFINTFSServiceError.missingImage
        }

        let imageURL = URL(fileURLWithPath: imagePath)
        let expectedBytes = (try? imageURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
        _ = try await privileged.writeRaw(
            input: .file(imageURL),
            to: partition.deviceNode.replacingOccurrences(of: "/dev/disk", with: "/dev/rdisk"),
            expectedBytes: expectedBytes,
            phase: "UEFI:NTFS",
            message: "Staging the UEFI helper partition.",
            targetExpectation: nil,
            eventHandler: eventHandler
        )
    }
}
