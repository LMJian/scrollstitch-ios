import XCTest
@testable import ScrollStitchCore

final class ProductInformationTests: XCTestCase {
    func testOfflineDocumentWorksWithoutPublicLinks() throws {
        let data = Data(#"{"schemaVersion":1,"policyVersion":"2026-10-17","effectiveDate":"2026-10-17","sections":[{"title":"本机处理","body":"素材保存在本机。"}]}"#.utf8)
        let info = try ProductInformation.decode(data)
        XCTAssertEqual(info.sections.first?.title, "本机处理")
        XCTAssertNil(info.supportLink)
        XCTAssertNil(info.privacyLink)
    }
    func testFutureAndCorruptDocumentsFailClosed() {
        for json in [#"{"schemaVersion":2,"policyVersion":"2","effectiveDate":"2026-10-17","sections":[{"title":"a","body":"b"}],"supportURL":"https://apple.com/support"}"#,
                     #"{"schemaVersion":1,"policyVersion":"1","effectiveDate":"2026-10-17","sections":[]}"#, "invalid"] {
            XCTAssertThrowsError(try ProductInformation.decode(Data(json.utf8)))
        }
    }
    func testExternalLinksOnlyAllowNonPlaceholderHTTPS() {
        for text in ["http://apple.com", "javascript:alert(1)", "file:///tmp/a", "https://user:pass@apple.com", "https://127.0.0.1", "https://[::1]", "https://app.local", "https://example.com/privacy", "https://foo.example.org", "https://apple.com:8443", " https://apple.com", "https://apple.com\n", "https://apple.com\\@local"] {
            XCTAssertNil(ProductInformation.safeHTTPS(text), text)
        }
        XCTAssertEqual(ProductInformation.safeHTTPS("https://www.apple.com/legal/privacy/")?.host, "www.apple.com")
    }
}
