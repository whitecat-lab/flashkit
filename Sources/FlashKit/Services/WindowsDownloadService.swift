import Foundation

enum WindowsDownloadServiceError: LocalizedError {
    case unavailableCatalog
    case invalidResponse
    case unavailableLanguageCatalog
    case unavailableDownloadLinks

    var errorDescription: String? {
        switch self {
        case .unavailableCatalog:
            return "The official download catalog could not be loaded."
        case .invalidResponse:
            return "Microsoft returned an unexpected response while preparing the ISO download."
        case .unavailableLanguageCatalog:
            return "The available Windows ISO languages could not be loaded from Microsoft's servers."
        case .unavailableDownloadLinks:
            return "The official Windows ISO download links could not be loaded from Microsoft's servers."
        }
    }
}

struct WindowsDownloadService: @unchecked Sendable {
    private let session: URLSession
    private let fileManager: FileManager
    private let chunkSize = 1024 * 1024

    private let organizationID = "y6jn8c31"
    private let profileID = "606624d44113"
    private let instanceID = "560dc9f3-1aa5-4a2f-b63c-9e18f8d0e175"

    init(session: URLSession? = nil, fileManager: FileManager = .default) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.default
            configuration.httpCookieStorage = .shared
            configuration.httpShouldSetCookies = true
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            self.session = URLSession(configuration: configuration)
        }
        self.fileManager = fileManager
    }

    func officialCatalogEntries(cacheDirectory: URL? = nil) async throws -> [WindowsDownloadCatalogProduct] {
        let cacheURL = catalogCacheURL(in: cacheDirectory)

        do {
            let entries = try await liveCatalogEntries()
            try fileManager.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(entries).write(to: cacheURL, options: .atomic)
            return entries
        } catch {
            if let cached = try? Data(contentsOf: cacheURL),
               let decoded = try? JSONDecoder.microsoft.decode([WindowsDownloadCatalogProduct].self, from: cached),
               !decoded.isEmpty {
                return decoded
            }
            throw error
        }
    }

    func loadLanguages(
        for product: WindowsDownloadCatalogProduct,
        release: WindowsDownloadRelease,
        edition: WindowsDownloadEdition,
        locale: String = "en-US",
        cacheDirectory: URL? = nil
    ) async throws -> [WindowsDownloadLanguageOption] {
        if product.family == .uefiShell {
            guard let links = edition.directLinks, !links.isEmpty else {
                throw WindowsDownloadServiceError.unavailableLanguageCatalog
            }
            return [
                WindowsDownloadLanguageOption(
                    id: "universal",
                    displayName: "Universal",
                    localeName: "Universal",
                    skuEntries: [],
                    directLinks: links
                )
            ]
        }

        let cacheURL = languagesCacheURL(for: product, release: release, edition: edition, in: cacheDirectory)
        if let cached = try? Data(contentsOf: cacheURL),
           let decoded = try? JSONDecoder.microsoft.decode([WindowsDownloadLanguageOption].self, from: cached),
           !decoded.isEmpty {
            return decoded
        }

        var languagesByDisplayName: [String: (localeName: String, entries: [WindowsDownloadSKUEntry])] = [:]
        let refererURL = pageURL(for: product)

        _ = try await session.data(from: refererURL)

        for productEditionID in edition.productEditionIDs {
            let sessionID = UUID().uuidString.lowercased()
            try await registerSession(sessionID: sessionID)

            let skuInfo = try await fetchSKUInformation(
                productEditionID: productEditionID,
                locale: locale,
                sessionID: sessionID,
                refererURL: refererURL
            )

            for sku in skuInfo.skus {
                var bucket = languagesByDisplayName[sku.localizedLanguage] ?? (sku.language, [])
                bucket.entries.append(
                    WindowsDownloadSKUEntry(
                        sessionID: sessionID,
                        skuID: sku.id,
                        refererPath: product.pagePath
                    )
                )
                languagesByDisplayName[sku.localizedLanguage] = bucket
            }
        }

        let languages = languagesByDisplayName.keys.sorted().map { key in
            let bucket = languagesByDisplayName[key]!
            return WindowsDownloadLanguageOption(
                id: bucket.localeName.lowercased(),
                displayName: key,
                localeName: bucket.localeName,
                skuEntries: bucket.entries,
                directLinks: nil
            )
        }

        guard !languages.isEmpty else {
            throw WindowsDownloadServiceError.unavailableLanguageCatalog
        }

        try fileManager.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(languages).write(to: cacheURL, options: .atomic)
        return languages
    }

    func loadDownloadLinks(
        for product: WindowsDownloadCatalogProduct,
        language: WindowsDownloadLanguageOption,
        locale: String = "en-US",
        cacheDirectory: URL? = nil
    ) async throws -> [WindowsDownloadLinkOption] {
        if product.family == .uefiShell, let directLinks = language.directLinks, !directLinks.isEmpty {
            return directLinks.sorted { $0.architecture.sortIndex < $1.architecture.sortIndex }
        }

        let cacheURL = linksCacheURL(for: product, language: language, in: cacheDirectory)
        if let cached = try? Data(contentsOf: cacheURL),
           let decoded = try? JSONDecoder.microsoft.decode([WindowsDownloadLinkOption].self, from: cached),
           !decoded.isEmpty,
           decoded.contains(where: { $0.expirationDate ?? .distantFuture > .now }) {
            return decoded
        }

        let refererURL = pageURL(for: product)
        var dedupedByArchitecture: [WindowsDownloadArchitecture: WindowsDownloadLinkOption] = [:]

        for skuEntry in language.skuEntries {
            var components = URLComponents(string: "https://www.microsoft.com/software-download-connector/api/GetProductDownloadLinksBySku")!
            components.queryItems = [
                URLQueryItem(name: "profile", value: profileID),
                URLQueryItem(name: "productEditionId", value: "undefined"),
                URLQueryItem(name: "SKU", value: skuEntry.skuID),
                URLQueryItem(name: "friendlyFileName", value: "undefined"),
                URLQueryItem(name: "Locale", value: locale),
                URLQueryItem(name: "sessionID", value: skuEntry.sessionID),
            ]

            var request = URLRequest(url: components.url!)
            request.setValue(refererURL.absoluteString, forHTTPHeaderField: "Referer")
            let (data, _) = try await session.data(for: request)
            let response = try JSONDecoder.microsoft.decode(ProductDownloadLinksResponse.self, from: data)
            if let firstError = response.validationContainer.errors.first ?? response.errors?.first {
                throw ResponseError(message: firstError.value)
            }

            for option in response.productDownloadOptions {
                guard let architecture = WindowsDownloadArchitecture(downloadType: option.downloadType) else {
                    continue
                }
                let filename = option.uri.lastPathComponent.isEmpty
                    ? "\(product.title.replacingOccurrences(of: " ", with: "_"))-\(architecture.rawValue).iso"
                    : option.uri.lastPathComponent
                dedupedByArchitecture[assemblyArchitectureKey(for: architecture)] = WindowsDownloadLinkOption(
                    id: architecture.rawValue,
                    architecture: architecture,
                    displayName: option.localizedProductDisplayName,
                    url: option.uri,
                    filename: filename,
                    expirationDate: response.downloadExpirationDate
                )
            }
        }

        let links = dedupedByArchitecture.values.sorted { $0.architecture.sortIndex < $1.architecture.sortIndex }
        guard !links.isEmpty else {
            throw WindowsDownloadServiceError.unavailableDownloadLinks
        }

        try fileManager.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(links).write(to: cacheURL, options: .atomic)
        return links
    }

    func download(
        title: String,
        from sourceURL: URL,
        to destinationURL: URL
    ) async throws -> DownloadJob {
        if sourceURL.isFileURL {
            return try resumeLocalCopy(title: title, from: sourceURL, to: destinationURL)
        }

        return try await streamRemoteDownload(title: title, from: sourceURL, to: destinationURL)
    }

    func catalogCacheURL(in cacheDirectory: URL? = nil) -> URL {
        let root = cacheDirectory ?? defaultCacheDirectory()
        return root.appending(path: "windows-download-catalog.json")
    }

    func resumeMetadataURL(for destinationURL: URL) -> URL {
        destinationURL.appendingPathExtension("windiskwriter.resume.json")
    }

    func languagesCacheURL(
        for product: WindowsDownloadCatalogProduct,
        release: WindowsDownloadRelease,
        edition: WindowsDownloadEdition,
        in cacheDirectory: URL? = nil
    ) -> URL {
        let root = cacheDirectory ?? defaultCacheDirectory()
        return root
            .appending(path: "catalog", directoryHint: .isDirectory)
            .appending(path: "\(product.id)-\(release.id)-\(edition.id)-languages.json")
    }

    func linksCacheURL(
        for product: WindowsDownloadCatalogProduct,
        language: WindowsDownloadLanguageOption,
        in cacheDirectory: URL? = nil
    ) -> URL {
        let root = cacheDirectory ?? defaultCacheDirectory()
        return root
            .appending(path: "catalog", directoryHint: .isDirectory)
            .appending(path: "\(product.id)-\(language.id)-links.json")
    }

    private func pageURL(for product: WindowsDownloadCatalogProduct) -> URL {
        if let directURL = URL(string: product.pagePath), product.pagePath.hasPrefix("http") {
            return directURL
        }
        return URL(string: "https://www.microsoft.com/en-us/software-download/\(product.pagePath)")!
    }

    private func liveCatalogEntries() async throws -> [WindowsDownloadCatalogProduct] {
        var entries: [WindowsDownloadCatalogProduct] = []
        entries.append((try? await fetchWindowsCatalogProduct(id: "windows11", pagePath: "windows11")) ?? fallbackWindowsCatalogProduct(id: "windows11"))
        entries.append((try? await fetchWindowsCatalogProduct(id: "windows10", pagePath: "windows10ISO")) ?? fallbackWindowsCatalogProduct(id: "windows10"))
        if let windows8 = try? await fetchWindowsCatalogProduct(id: "windows8", pagePath: "windows8ISO") {
            entries.append(windows8)
        }
        if let shell = try? await fetchUEFIShellCatalogProduct() {
            entries.append(shell)
        }
        guard !entries.isEmpty else {
            throw WindowsDownloadServiceError.unavailableCatalog
        }
        return entries
    }

    private func fetchWindowsCatalogProduct(id: String, pagePath: String) async throws -> WindowsDownloadCatalogProduct {
        let url = URL(string: "https://www.microsoft.com/en-us/software-download/\(pagePath)")!
        let (data, _) = try await session.data(from: url)
        let html = String(decoding: data, as: UTF8.self)
        let title = (try? firstRegexMatch(in: html, pattern: #"<title>\s*([^<]+?)\s*</title>"#)) ?? id
        let optionExpression = try NSRegularExpression(pattern: #"<option value="(\d+)">([^<]+)</option>"#, options: [.caseInsensitive])
        let optionText = html as NSString
        let matches = optionExpression.matches(in: html, range: NSRange(location: 0, length: optionText.length))

        let editions = matches.compactMap { match -> WindowsDownloadEdition? in
            guard match.numberOfRanges >= 3,
                  let productID = Int(optionText.substring(with: match.range(at: 1))) else {
                return nil
            }

            let rawTitle = optionText.substring(with: match.range(at: 2))
            let cleanTitle = rawTitle.replacingOccurrences(of: "&amp;", with: "&")
            return WindowsDownloadEdition(
                id: "\(id)-\(productID)",
                title: cleanTitle,
                productEditionIDs: [productID],
                directLinks: nil
            )
        }

        guard !editions.isEmpty else {
            throw WindowsDownloadServiceError.unavailableCatalog
        }

        return WindowsDownloadCatalogProduct(
            id: id,
            title: sanitizedCatalogTitle(title),
            pagePath: pagePath,
            family: .windows,
            releases: [
                WindowsDownloadRelease(
                    id: "\(id)-current",
                    title: "Current release",
                    editions: editions
                )
            ]
        )
    }

    private func fallbackWindowsCatalogProduct(id: String) -> WindowsDownloadCatalogProduct {
        switch id {
        case "windows11":
            return WindowsDownloadCatalogProduct(
                id: "windows11",
                title: "Windows 11",
                pagePath: "windows11",
                family: .windows,
                releases: [
                    WindowsDownloadRelease(
                        id: "windows11-current",
                        title: "Current release",
                        editions: [
                            WindowsDownloadEdition(
                                id: "windows11-3321",
                                title: "Windows 11 (multi-edition ISO for x64 devices)",
                                productEditionIDs: [3321],
                                directLinks: nil
                            )
                        ]
                    )
                ]
            )
        default:
            return WindowsDownloadCatalogProduct(
                id: "windows10",
                title: "Windows 10",
                pagePath: "windows10ISO",
                family: .windows,
                releases: [
                    WindowsDownloadRelease(
                        id: "windows10-current",
                        title: "Current release",
                        editions: [
                            WindowsDownloadEdition(
                                id: "windows10-2618",
                                title: "Windows 10 (multi-edition ISO)",
                                productEditionIDs: [2618],
                                directLinks: nil
                            )
                        ]
                    )
                ]
            )
        }
    }

    private func fetchUEFIShellCatalogProduct() async throws -> WindowsDownloadCatalogProduct {
        let url = URL(string: "https://api.github.com/repos/pbatard/UEFI-Shell/releases?per_page=6")!
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("FlashKit", forHTTPHeaderField: "User-Agent")
        let (data, _) = try await session.data(for: request)
        let releases = try JSONDecoder().decode([GitHubRelease].self, from: data)

        let catalogReleases = releases.compactMap { release -> WindowsDownloadRelease? in
            let isoAssets = release.assets.compactMap { asset -> WindowsDownloadLinkOption? in
                guard asset.name.lowercased().hasSuffix(".iso") else {
                    return nil
                }
                return WindowsDownloadLinkOption(
                    id: asset.name.lowercased(),
                    architecture: architecture(forUEFIShellAssetNamed: asset.name),
                    displayName: release.name ?? release.tagName,
                    url: asset.browserDownloadURL,
                    filename: asset.name,
                    expirationDate: nil
                )
            }

            guard !isoAssets.isEmpty else {
                return nil
            }

            return WindowsDownloadRelease(
                id: release.tagName,
                title: release.name ?? release.tagName,
                editions: [
                    WindowsDownloadEdition(
                        id: "\(release.tagName)-iso",
                        title: "UEFI Shell ISO",
                        productEditionIDs: [],
                        directLinks: isoAssets
                    )
                ]
            )
        }

        guard !catalogReleases.isEmpty else {
            throw WindowsDownloadServiceError.unavailableCatalog
        }

        return WindowsDownloadCatalogProduct(
            id: "uefi-shell",
            title: "UEFI Shell",
            pagePath: "https://github.com/pbatard/UEFI-Shell/releases",
            family: .uefiShell,
            releases: catalogReleases
        )
    }

    private func architecture(forUEFIShellAssetNamed name: String) -> WindowsDownloadArchitecture {
        let lowercased = name.lowercased()
        if lowercased.contains("aa64") || lowercased.contains("arm64") || lowercased.contains("aarch64") {
            return .arm64
        }
        if lowercased.contains("ia32") || lowercased.contains("x86") {
            return .x86
        }
        return .x64
    }

    private func sanitizedCatalogTitle(_ title: String) -> String {
        title
            .replacingOccurrences(of: "Download ", with: "")
            .replacingOccurrences(of: " Disc Image (ISO File)", with: "")
            .replacingOccurrences(of: " ISOs for X64", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func registerSession(sessionID: String) async throws {
        let tagsURL = URL(
            string: "https://vlscppe.microsoft.com/tags?org_id=\(organizationID)&session_id=\(sessionID)"
        )!
        _ = try await session.data(from: tagsURL)

        let mdtURL = URL(
            string: "https://ov-df.microsoft.com/mdt.js?instanceId=\(instanceID)&PageId=si&session_id=\(sessionID)"
        )!
        let (mdtData, _) = try await session.data(from: mdtURL)
        let mdtText = String(decoding: mdtData, as: UTF8.self)
        let w = try firstRegexMatch(in: mdtText, pattern: #"[?&]w=([A-F0-9]+)"#)
        let rticks = try firstRegexMatch(in: mdtText, pattern: #"rticks\=\"\+?(\d+)"#)

        let replyURL = URL(
            string: "https://ov-df.microsoft.com/?session_id=\(sessionID)&CustomerId=\(instanceID)&PageId=si&w=\(w)&mdt=\(Int(Date.now.timeIntervalSince1970 * 1000))&rticks=\(rticks)"
        )!
        _ = try await session.data(from: replyURL)
    }

    private func fetchSKUInformation(
        productEditionID: Int,
        locale: String,
        sessionID: String,
        refererURL: URL
    ) async throws -> SKUInformationResponse {
        var components = URLComponents(string: "https://www.microsoft.com/software-download-connector/api/getskuinformationbyproductedition")!
        components.queryItems = [
            URLQueryItem(name: "profile", value: profileID),
            URLQueryItem(name: "productEditionId", value: String(productEditionID)),
            URLQueryItem(name: "SKU", value: "undefined"),
            URLQueryItem(name: "friendlyFileName", value: "undefined"),
            URLQueryItem(name: "Locale", value: locale),
            URLQueryItem(name: "sessionID", value: sessionID),
        ]

        var request = URLRequest(url: components.url!)
        request.setValue(refererURL.absoluteString, forHTTPHeaderField: "Referer")

        let (data, _) = try await session.data(for: request)
        let response = try JSONDecoder.microsoft.decode(SKUInformationResponse.self, from: data)
        if let firstError = response.errors?.first {
            throw ResponseError(message: firstError.value)
        }
        return response
    }

    private func firstRegexMatch(in text: String, pattern: String) throws -> String {
        let expression = try NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators, .caseInsensitive])
        let nsText = text as NSString
        guard let match = expression.firstMatch(in: text, range: NSRange(location: 0, length: nsText.length)),
              match.numberOfRanges > 1 else {
            throw WindowsDownloadServiceError.invalidResponse
        }
        return nsText.substring(with: match.range(at: 1))
    }

    private func assemblyArchitectureKey(for architecture: WindowsDownloadArchitecture) -> WindowsDownloadArchitecture {
        architecture
    }

    private func resumeLocalCopy(title: String, from sourceURL: URL, to destinationURL: URL) throws -> DownloadJob {
        let sourceSize = try sourceURL.resourceValues(forKeys: [.fileSizeKey]).fileSize.map(Int64.init) ?? 0
        try fileManager.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        var receivedBytes = currentSize(of: destinationURL)
        if receivedBytes > sourceSize {
            try fileManager.removeItem(at: destinationURL)
            receivedBytes = 0
        }

        let metadataURL = resumeMetadataURL(for: destinationURL)
        try writeResumeMetadata(title: title, sourceURL: sourceURL, destinationURL: destinationURL, bytesReceived: receivedBytes, expectedBytes: sourceSize)

        let sourceHandle = try FileHandle(forReadingFrom: sourceURL)
        defer { try? sourceHandle.close() }

        if !fileManager.fileExists(atPath: destinationURL.path()) {
            fileManager.createFile(atPath: destinationURL.path(), contents: Data())
        }
        let destinationHandle = try FileHandle(forUpdating: destinationURL)
        defer { try? destinationHandle.close() }

        if receivedBytes > 0 {
            try sourceHandle.seek(toOffset: UInt64(receivedBytes))
            try destinationHandle.seekToEnd()
        } else {
            try destinationHandle.truncate(atOffset: 0)
        }

        while true {
            let data = try sourceHandle.read(upToCount: chunkSize) ?? Data()
            if data.isEmpty {
                break
            }

            try destinationHandle.write(contentsOf: data)
            receivedBytes += Int64(data.count)
            try writeResumeMetadata(title: title, sourceURL: sourceURL, destinationURL: destinationURL, bytesReceived: receivedBytes, expectedBytes: sourceSize)
        }

        try? fileManager.removeItem(at: metadataURL)

        return DownloadJob(
            id: UUID(),
            title: title,
            sourceURL: sourceURL,
            destinationURL: destinationURL,
            state: .completed,
            bytesReceived: receivedBytes,
            expectedBytes: sourceSize,
            resumeDataPath: nil
        )
    }

    private func streamRemoteDownload(title: String, from sourceURL: URL, to destinationURL: URL) async throws -> DownloadJob {
        try fileManager.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        var receivedBytes = currentSize(of: destinationURL)
        let metadataURL = resumeMetadataURL(for: destinationURL)
        var request = URLRequest(url: sourceURL, cachePolicy: .reloadIgnoringLocalCacheData)

        if let expectedBytes = try await remoteExpectedBytes(for: sourceURL), receivedBytes >= expectedBytes {
            return DownloadJob(
                id: UUID(),
                title: title,
                sourceURL: sourceURL,
                destinationURL: destinationURL,
                state: .completed,
                bytesReceived: expectedBytes,
                expectedBytes: expectedBytes,
                resumeDataPath: nil
            )
        }

        if receivedBytes > 0 {
            request.setValue("bytes=\(receivedBytes)-", forHTTPHeaderField: "Range")
        }

        let (bytes, response) = try await session.bytes(for: request)
        let httpResponse = response as? HTTPURLResponse
        let isPartialResponse = httpResponse?.statusCode == 206
        let responseExpectedBytes = response.expectedContentLength > 0 ? response.expectedContentLength : nil

        if !isPartialResponse && receivedBytes > 0 {
            if fileManager.fileExists(atPath: destinationURL.path()) {
                try fileManager.removeItem(at: destinationURL)
            }
            receivedBytes = 0
        }

        if !fileManager.fileExists(atPath: destinationURL.path()) {
            fileManager.createFile(atPath: destinationURL.path(), contents: Data())
        }
        let destinationHandle = try FileHandle(forUpdating: destinationURL)
        defer { try? destinationHandle.close() }

        if receivedBytes > 0 {
            try destinationHandle.seekToEnd()
        } else {
            try destinationHandle.truncate(atOffset: 0)
        }

        let totalExpectedBytes: Int64? = {
            guard let responseExpectedBytes else { return nil }
            return isPartialResponse ? receivedBytes + responseExpectedBytes : responseExpectedBytes
        }()

        try writeResumeMetadata(title: title, sourceURL: sourceURL, destinationURL: destinationURL, bytesReceived: receivedBytes, expectedBytes: totalExpectedBytes)

        var buffer = Data()
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= chunkSize {
                try destinationHandle.write(contentsOf: buffer)
                receivedBytes += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                try writeResumeMetadata(title: title, sourceURL: sourceURL, destinationURL: destinationURL, bytesReceived: receivedBytes, expectedBytes: totalExpectedBytes)
            }
        }

        if !buffer.isEmpty {
            try destinationHandle.write(contentsOf: buffer)
            receivedBytes += Int64(buffer.count)
        }

        try? fileManager.removeItem(at: metadataURL)

        return DownloadJob(
            id: UUID(),
            title: title,
            sourceURL: sourceURL,
            destinationURL: destinationURL,
            state: .completed,
            bytesReceived: receivedBytes,
            expectedBytes: totalExpectedBytes,
            resumeDataPath: nil
        )
    }

    private func currentSize(of url: URL) -> Int64 {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize.map(Int64.init)) ?? 0
    }

    private func remoteExpectedBytes(for sourceURL: URL) async throws -> Int64? {
        var request = URLRequest(url: sourceURL, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = "HEAD"
        let (_, response) = try await session.data(for: request)
        return response.expectedContentLength > 0 ? response.expectedContentLength : nil
    }

    private func writeResumeMetadata(
        title: String,
        sourceURL: URL,
        destinationURL: URL,
        bytesReceived: Int64,
        expectedBytes: Int64?
    ) throws {
        let metadata = ResumeMetadata(
            title: title,
            sourceURL: sourceURL,
            destinationURL: destinationURL,
            bytesReceived: bytesReceived,
            expectedBytes: expectedBytes
        )
        let data = try JSONEncoder().encode(metadata)
        try data.write(to: resumeMetadataURL(for: destinationURL), options: .atomic)
    }

    private func defaultCacheDirectory() -> URL {
        fileManager.homeDirectoryForCurrentUser
            .appending(path: "Library")
            .appending(path: "Caches")
            .appending(path: "FlashKit")
    }
}

private struct ResumeMetadata: Codable {
    let title: String
    let sourceURL: URL
    let destinationURL: URL
    let bytesReceived: Int64
    let expectedBytes: Int64?
}

private struct SKUInformationResponse: Decodable {
    let skus: [SKUInformationItem]
    let errors: [ResponseError]?

    enum CodingKeys: String, CodingKey {
        case skus = "Skus"
        case errors = "Errors"
    }
}

private struct SKUInformationItem: Decodable {
    let id: String
    let language: String
    let localizedLanguage: String

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case language = "Language"
        case localizedLanguage = "LocalizedLanguage"
    }
}

private struct ProductDownloadLinksResponse: Decodable {
    let productDownloadOptions: [ProductDownloadOption]
    let validationContainer: ValidationContainer
    let errors: [ResponseError]?
    let downloadExpirationDate: Date?

    enum CodingKeys: String, CodingKey {
        case productDownloadOptions = "ProductDownloadOptions"
        case validationContainer = "ValidationContainer"
        case errors = "Errors"
        case downloadExpirationDate = "DownloadExpirationDatetime"
    }
}

private struct ProductDownloadOption: Decodable {
    let uri: URL
    let localizedProductDisplayName: String
    let downloadType: Int

    enum CodingKeys: String, CodingKey {
        case uri = "Uri"
        case localizedProductDisplayName = "LocalizedProductDisplayName"
        case downloadType = "DownloadType"
    }
}

private struct ValidationContainer: Decodable {
    let errors: [ResponseError]

    enum CodingKeys: String, CodingKey {
        case errors = "Errors"
    }
}

private struct ResponseError: Decodable, Error {
    let value: String

    init(message: String) {
        self.value = message
    }

    enum CodingKeys: String, CodingKey {
        case value = "Value"
    }
}

private struct GitHubRelease: Decodable {
    let tagName: String
    let name: String?
    let assets: [GitHubReleaseAsset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case assets
    }
}

private struct GitHubReleaseAsset: Decodable {
    let name: String
    let browserDownloadURL: URL

    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
    }
}

private extension JSONDecoder {
    static var microsoft: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

private extension WindowsDownloadArchitecture {
    init?(downloadType: Int) {
        switch downloadType {
        case 0:
            self = .x86
        case 1:
            self = .x64
        case 2:
            self = .arm64
        default:
            return nil
        }
    }

    var sortIndex: Int {
        switch self {
        case .x64:
            return 0
        case .arm64:
            return 1
        case .x86:
            return 2
        }
    }
}
