import Foundation

struct AppliedCustomization: Sendable {
    let placement: CustomizationPlacement
    let destinationURL: URL
}

struct WindowsCustomizationService {
    func applyCustomization(
        profile: SourceImageProfile,
        destinationRoot: URL?,
        ntfsDestinationPartition: DiskPartition?,
        customization: CustomizationProfile,
        toolchain: ToolchainStatus,
        ntfsPopulateService: NTFSPopulateService
    ) async throws -> AppliedCustomization? {
        guard customization.isEnabled else {
            return nil
        }

        if profile.windows?.hasPantherUnattend == true {
            return nil
        }

        let placement = customization.preferredPlacement
        let xml = renderUnattendXML(customization: customization)

        if let destinationRoot {
            let destinationURL = destinationRoot.appending(path: placement.relativePath)
            try FileManager.default.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try xml.write(to: destinationURL, atomically: true, encoding: .utf8)
            return AppliedCustomization(placement: placement, destinationURL: destinationURL)
        }

        guard let ntfsDestinationPartition else {
            return nil
        }

        let temporaryRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let destinationURL = temporaryRoot.appending(path: placement.relativePath)
        try FileManager.default.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try xml.write(to: destinationURL, atomically: true, encoding: .utf8)
        try await ntfsPopulateService.copyContents(
            from: temporaryRoot,
            to: ntfsDestinationPartition,
            skippingRelativePath: nil,
            toolchain: toolchain
        )
        try? FileManager.default.removeItem(at: temporaryRoot)

        return AppliedCustomization(placement: placement, destinationURL: destinationURL)
    }

    private func renderUnattendXML(customization: CustomizationProfile) -> String {
        let sanitizedAccountName = customization.localAccountName.flatMap { name -> String? in
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : sanitizedLocalAccountName(trimmed)
        }

        let localAccountSection: String
        let firstLogonCommands: String
        if customization.preferLocalAccount, let localAccountName = sanitizedAccountName {
            localAccountSection = """
                        <LocalAccounts>
                            <LocalAccount wcm:action="add">
                                <Group>Administrators;Power Users</Group>
                                <Name>\(sanitizedLocalAccountName(localAccountName))</Name>
                                <DisplayName>\(sanitizedLocalAccountName(localAccountName))</DisplayName>
                                <Password>
                                    <Value>UABhAHMAcwB3AG8AcgBkAA==</Value>
                                    <PlainText>false</PlainText>
                                </Password>
                            </LocalAccount>
                        </LocalAccounts>
            """
            firstLogonCommands = """
                        <FirstLogonCommands>
                            <SynchronousCommand wcm:action="add">
                                <Order>1</Order>
                                <CommandLine>net user &quot;\(sanitizedLocalAccountName(localAccountName))&quot; /logonpasswordchg:yes</CommandLine>
                            </SynchronousCommand>
                            <SynchronousCommand wcm:action="add">
                                <Order>2</Order>
                                <CommandLine>net accounts /maxpwage:unlimited</CommandLine>
                            </SynchronousCommand>
                        </FirstLogonCommands>
            """
        } else {
            localAccountSection = ""
            firstLogonCommands = ""
        }

        let bypassBlock = customization.bypassSecureBootTPMRAMChecks ? """
                        <UserData>
                            <ProductKey>
                                <Key />
                            </ProductKey>
                        </UserData>
                        <RunSynchronous>
                            <RunSynchronousCommand wcm:action="add">
                                <Order>1</Order>
                                <Path>reg add HKLM\\SYSTEM\\Setup\\LabConfig /v BypassTPMCheck /t REG_DWORD /d 1 /f</Path>
                            </RunSynchronousCommand>
                            <RunSynchronousCommand wcm:action="add">
                                <Order>2</Order>
                                <Path>reg add HKLM\\SYSTEM\\Setup\\LabConfig /v BypassSecureBootCheck /t REG_DWORD /d 1 /f</Path>
                            </RunSynchronousCommand>
                            <RunSynchronousCommand wcm:action="add">
                                <Order>3</Order>
                                <Path>reg add HKLM\\SYSTEM\\Setup\\LabConfig /v BypassRAMCheck /t REG_DWORD /d 1 /f</Path>
                            </RunSynchronousCommand>
                        </RunSynchronous>
        """ : ""

        let specializeBlock = customization.bypassOnlineAccountRequirement ? """
                        <RunSynchronous>
                            <RunSynchronousCommand wcm:action="add">
                                <Order>1</Order>
                                <Path>reg add HKLM\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\OOBE /v BypassNRO /t REG_DWORD /d 1 /f</Path>
                            </RunSynchronousCommand>
                        </RunSynchronous>
        """ : ""

        let privacyBlock = customization.disableDataCollection ? """
                        <OOBE>
                            <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
                            <ProtectYourPC>3</ProtectYourPC>
                        </OOBE>
        """ : ""

        let localeBlock = customization.duplicateHostLocale ? """
                        <TimeZone>\(hostTimeZoneIdentifier())</TimeZone>
        """ : ""

        let internationalBlock = customization.duplicateHostLocale ? """
            <settings pass="oobeSystem">
                <component name="Microsoft-Windows-International-Core" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
                    <InputLocale>\(hostInputLocale())</InputLocale>
                    <SystemLocale>\(hostLocaleIdentifier())</SystemLocale>
                    <UserLocale>\(hostLocaleIdentifier())</UserLocale>
                    <UILanguage>\(hostLocaleIdentifier())</UILanguage>
                    <UILanguageFallback>\(hostLocaleIdentifier())</UILanguageFallback>
                </component>
            </settings>
        """ : ""

        let bitLockerBlock = customization.disableBitLocker ? """
            <settings pass="oobeSystem">
                <component name="Microsoft-Windows-SecureStartup-FilterDriver" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
                    <PreventDeviceEncryption>true</PreventDeviceEncryption>
                </component>
                <component name="Microsoft-Windows-EnhancedStorage-Adm" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
                    <TCGSecurityActivationDisabled>1</TCGSecurityActivationDisabled>
                </component>
            </settings>
        """ : ""

        return """
        <?xml version="1.0" encoding="utf-8"?>
        <unattend xmlns="urn:schemas-microsoft-com:unattend" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
            <settings pass="windowsPE">
                <component name="Microsoft-Windows-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
        \(bypassBlock)
                </component>
            </settings>
            <settings pass="specialize">
                <component name="Microsoft-Windows-Deployment" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
        \(specializeBlock)
                </component>
            </settings>
            <settings pass="oobeSystem">
                <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
        \(privacyBlock)
        \(localeBlock)
        \(localAccountSection)
        \(firstLogonCommands)
                </component>
            </settings>
        \(internationalBlock)
        \(bitLockerBlock)
        </unattend>
        """
    }

    private func sanitizedLocalAccountName(_ name: String) -> String {
        let invalidCharacters = CharacterSet(charactersIn: "/\\[]:|<>+=;,?*%@.")
        return name.unicodeScalars.map { scalar in
            invalidCharacters.contains(scalar) ? "_" : String(scalar)
        }.joined()
    }

    private func hostLocaleIdentifier() -> String {
        Locale.autoupdatingCurrent.identifier.replacingOccurrences(of: "_", with: "-")
    }

    private func hostInputLocale() -> String {
        Locale.autoupdatingCurrent.identifier.replacingOccurrences(of: "_", with: "-")
    }

    private func hostTimeZoneIdentifier() -> String {
        TimeZone.autoupdatingCurrent.identifier
    }
}
