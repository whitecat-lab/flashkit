import Foundation

struct ImageBinaryProbeService {
    private let hybridDetector = ISOHybridDetector()

    func probeFile(at sourceURL: URL, declaredFormat: SourceImageFormat) throws -> ImageBinaryProbe {
        let values = try sourceURL.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
        let fileSize = values.fileSize.map(Int64.init) ?? 0

        guard values.isDirectory != true else {
            return .synthetic(sourceURL: sourceURL, fileSize: fileSize, declaredFormat: declaredFormat)
        }

        let handle = try FileHandle(forReadingFrom: sourceURL)
        defer { try? handle.close() }

        let sector0 = try read(from: handle, offset: 0, count: 512)
        let sector1 = try read(from: handle, offset: 512, count: 512)
        let opticalDescriptors = try read(from: handle, offset: 16 * 2_048, count: 8 * 2_048)

        let hasGzipMagic = sector0.starts(with: [0x1F, 0x8B])
        let hasXZMagic = sector0.starts(with: [0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00])
        let hasISO9660Marker = containsISO9660Descriptor(in: opticalDescriptors)
        let hasUDFMarker = containsUDFDescriptor(in: opticalDescriptors)
        let hasMBRSignature = containsPartitionedMBR(in: sector0)
        let hasGPTSignature = containsGPTHeader(in: sector1)

        let isoHybridStyle: ISOHybridStyle
        if declaredFormat == .iso || declaredFormat == .udfISO || hasISO9660Marker || hasUDFMarker {
            isoHybridStyle = (try? hybridDetector.detectStyle(for: sourceURL)) ?? .nonHybrid
        } else {
            isoHybridStyle = .notApplicable
        }

        return ImageBinaryProbe(
            sourceURL: sourceURL,
            fileSize: fileSize,
            declaredFormat: declaredFormat,
            compression: RawDiskImageService.compression(for: sourceURL),
            hasGzipMagic: hasGzipMagic,
            hasXZMagic: hasXZMagic,
            hasISO9660Marker: hasISO9660Marker,
            hasUDFMarker: hasUDFMarker,
            hasMBRSignature: hasMBRSignature,
            hasGPTSignature: hasGPTSignature,
            isoHybridStyle: isoHybridStyle
        )
    }

    private func read(from handle: FileHandle, offset: UInt64, count: Int) throws -> Data {
        try handle.seek(toOffset: offset)
        return try handle.read(upToCount: count) ?? Data()
    }

    private func containsISO9660Descriptor(in data: Data) -> Bool {
        for descriptor in volumeDescriptors(in: data) {
            guard descriptor.count >= 7 else {
                continue
            }

            let identifier = Data(descriptor[1..<6])
            if String(decoding: identifier, as: UTF8.self) == "CD001" {
                return true
            }
        }

        return false
    }

    private func containsUDFDescriptor(in data: Data) -> Bool {
        for descriptor in volumeDescriptors(in: data) {
            guard descriptor.count >= 7 else {
                continue
            }

            let identifier = String(decoding: descriptor[1..<6], as: UTF8.self)
            if ["BEA01", "NSR02", "NSR03", "TEA01"].contains(identifier) {
                return true
            }
        }

        return false
    }

    private func volumeDescriptors(in data: Data) -> [Data] {
        guard !data.isEmpty else {
            return []
        }

        let sectorSize = 2_048
        return stride(from: 0, to: data.count, by: sectorSize).map { index in
            let upperBound = min(index + sectorSize, data.count)
            return Data(data[index..<upperBound])
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
