import Foundation

/// Bundled, offline information. Invalid or future schemas never expose external links.
public struct ProductInformation: Decodable, Sendable {
    public struct Section: Decodable, Sendable {
        public let title: String
        public let body: String
    }
    public let schemaVersion: Int
    public let policyVersion: String
    public let effectiveDate: String
    public let sections: [Section]
    private let supportURL: String?
    private let privacyURL: String?
    public var supportLink: URL? { schemaVersion == 1 ? Self.safeHTTPS(supportURL) : nil }
    public var privacyLink: URL? { schemaVersion == 1 ? Self.safeHTTPS(privacyURL) : nil }

    public static func decode(_ data: Data) throws -> Self {
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard value.schemaVersion == 1, !value.policyVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !value.effectiveDate.isEmpty, !value.sections.isEmpty,
              value.sections.allSatisfy({ !$0.title.isEmpty && !$0.body.isEmpty }) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return value
    }

    /// Reject credentials, local addresses, placeholders and non-HTTPS actions.
    public static func safeHTTPS(_ value: String?) -> URL? {
        guard let value, value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.contains("\\"), !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              let parts = URLComponents(string: value), parts.scheme?.lowercased() == "https",
              parts.user == nil, parts.password == nil, parts.port == nil || parts.port == 443,
              let host = parts.host?.lowercased(), !host.hasSuffix("."),
              host.contains("."), !host.contains(":"),
              !host.allSatisfy({ $0.isNumber || $0 == "." }),
              !["localhost", "local", "internal", "test", "invalid", "example", "example.com", "example.org", "example.net"].contains(where: { host == $0 || host.hasSuffix("." + $0) }),
              let url = parts.url else { return nil }
        return url
    }
}
