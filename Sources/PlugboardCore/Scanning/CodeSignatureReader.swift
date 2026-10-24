import Foundation
import Security

/// Reads who signed a bundle. Only the signature's metadata is read, so this stays fast
/// even for plug-ins with thousands of resource files.
public enum CodeSignatureReader {
    public static func read(_ url: URL) -> SignatureInfo {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess, let code = staticCode else {
            return .unknown
        }

        var infoRef: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        let result = SecCodeCopySigningInformation(code, flags, &infoRef)
        if result == errSecCSUnsigned { return SignatureInfo(status: .unsigned) }
        guard result == errSecSuccess, let info = infoRef as? [String: Any] else { return .unknown }

        let teamID = info[kSecCodeInfoTeamIdentifier as String] as? String
        let certificates = info[kSecCodeInfoCertificates as String] as? [SecCertificate] ?? []

        guard let leaf = certificates.first else {
            // A signature with no certificate chain is an ad-hoc signature.
            return info[kSecCodeInfoIdentifier as String] == nil
                ? SignatureInfo(status: .unsigned)
                : SignatureInfo(status: .adHoc)
        }

        let summary = (SecCertificateCopySubjectSummary(leaf) as String?) ?? ""
        let organization = organizationName(fromCertificateSummary: summary)

        let status: SignatureInfo.Status
        if summary.hasPrefix("Developer ID Application") {
            status = .developerID
        } else if summary.hasPrefix("Apple Mac OS Application Signing") || summary.hasPrefix("3rd Party Mac Developer") {
            status = .appStore
        } else if summary.hasPrefix("Software Signing") || summary.hasPrefix("Apple ") {
            status = .apple
        } else {
            status = .developerID
        }
        return SignatureInfo(status: status, organization: status == .apple ? "Apple" : organization, teamID: teamID)
    }

    /// "Developer ID Application: FabFilter B.V. (ABCDE12345)" → "FabFilter B.V.".
    public static func organizationName(fromCertificateSummary summary: String) -> String? {
        var name = summary
        if let colon = name.firstIndex(of: ":") {
            name = String(name[name.index(after: colon)...])
        }
        if let open = name.lastIndex(of: "("), name.hasSuffix(")") {
            name = String(name[..<open])
        }
        name = name.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }
}
