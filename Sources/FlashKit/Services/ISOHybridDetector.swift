import Foundation

struct ISOHybridDetector {
    func detectStyle(for sourceURL: URL) throws -> ISOHybridStyle {
        let handle = try FileHandle(forReadingFrom: sourceURL)
        defer { try? handle.close() }

        let sector0 = try handle.read(upToCount: 512) ?? Data()
        try handle.seek(toOffset: 512)
        let sector1 = try handle.read(upToCount: 512) ?? Data()

        let hasMBR = containsPartitionedMBR(in: sector0)
        let hasGPT = containsGPTHeader(in: sector1)

        switch (hasMBR, hasGPT) {
        case (true, true):
            return .hybridMBRAndGPT
        case (true, false):
            return .hybridMBR
        case (false, true):
            return .hybridGPT
        case (false, false):
            return .nonHybrid
        }
    }

    private func containsPartitionedMBR(in data: Data) -> Bool {
        guard data.count >= 512, data[510] == 0x55, data[511] == 0xAA else {
            return false
        }

        for entryIndex in 0..<4 {
            let base = 446 + (entryIndex * 16)
            guard data.count >= base + 16 else {
                continue
            }

            let entry = data[base..<(base + 16)]
            let partitionType = entry[entry.index(entry.startIndex, offsetBy: 4)]
            let sectorCountOffset = entry.index(entry.startIndex, offsetBy: 12)
            let sectorBytes = Array(entry[sectorCountOffset..<(sectorCountOffset + 4)])
            let sectorCount = sectorBytes.enumerated().reduce(UInt32(0)) { partial, item in
                partial | (UInt32(item.element) << (UInt32(item.offset) * 8))
            }

            if partitionType != 0 || sectorCount != 0 {
                return true
            }
        }

        return false
    }

    private func containsGPTHeader(in data: Data) -> Bool {
        guard data.count >= 8 else {
            return false
        }

        return String(decoding: data.prefix(8), as: UTF8.self) == "EFI PART"
    }
}
