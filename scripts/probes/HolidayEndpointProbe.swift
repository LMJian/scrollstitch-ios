import Foundation

/// Uses the actual HTTPS transport, validation and persistence without touching
/// user settings, the phone, the blog, or a system alarm service.
@main struct HolidayEndpointProbe {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = root.appendingPathComponent("calendar.json")
        // An empty bundle forces the production path to download annual bytes.
        let catalog = try WorkdayHolidayStore(bundleFiles: [], cacheURL: cache)
        let downloaded = try await catalog.refresh()
        guard downloaded > 0, !catalog.years.isEmpty else {
            throw WorkdayError.invalidData("No annual file downloaded")
        }
        let offline = try WorkdayHolidayStore(bundleFiles: [], cacheURL: cache, transport: Offline())
        guard offline.datasets == catalog.datasets else {
            throw WorkdayError.invalidData("Offline cache differs")
        }
        let revisions = catalog.years.keys.sorted().map { "\($0):v\(catalog.years[$0]!.dataset.revision)" }
        print("PASS: production HTTPS index, annual bytes, SHA256/schema and offline restart (\(revisions.joined(separator: ", ")))")
        print("Boundary: network and local persistence; no device AlarmKit or acoustic verification")
    }
    private struct Offline: HolidayTransport {
        func fetch(_ url: URL, maximumBytes: Int) async throws -> Data {
            throw WorkdayError.network("Offline verification must not request network")
        }
    }
}
