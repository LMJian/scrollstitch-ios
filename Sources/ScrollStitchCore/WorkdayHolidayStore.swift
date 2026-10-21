import Foundation

public protocol HolidayTransport: Sendable {
    func fetch(_ url: URL, maximumBytes: Int) async throws -> Data
}

/// No cookies, credentials or analytics. A redirect cannot change the data host.
public struct HolidayURLTransport: HolidayTransport {
    public init() {}
    public func fetch(_ url: URL, maximumBytes: Int) async throws -> Data {
        guard url.scheme == "https", url.user == nil, url.password == nil else {
            throw WorkdayError.network("下载地址必须使用 HTTPS")
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        let delegate = HolidayRedirectGuard()
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              response.url == url else { throw WorkdayError.network("下载入口暂不可用，请稍后重试") }
        guard response.expectedContentLength <= maximumBytes else { throw WorkdayError.invalidData("下载文件过大") }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < maximumBytes else { throw WorkdayError.invalidData("下载文件过大") }
            data.append(byte)
        }
        return data
    }
}

private final class HolidayRedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// One atomic file is the commit point for a multi-year update. Invalid downloads
/// never replace the last valid annual bytes. Bundle updates win over older caches.
@MainActor
public final class WorkdayHolidayStore {
    public static let endpoint = URL(string: "https://lmjian.github.io/assets/holidays/cn/index.json")!
    public struct Year: Sendable {
        public let dataset: HolidayDataset
        public let downloaded: Bool
        public let digest: String
    }
    private struct Cache: Codable {
        var schemaVersion = 1
        var files: [String: Data] = [:]
        var checkedAt: Date?
        var attemptedAt: Date?
    }
    public private(set) var years: [Int: Year] = [:]
    public private(set) var checkedAt: Date?
    public private(set) var attemptedAt: Date?
    public private(set) var warning: String?
    public private(set) var isUpdating = false
    public var datasets: [Int: HolidayDataset] { years.mapValues(\.dataset) }
    private let cacheURL: URL
    private let transport: any HolidayTransport
    private let endpoint: URL
    private var cache = Cache()

    public init(bundleFiles: [URL], cacheURL: URL, transport: any HolidayTransport = HolidayURLTransport(),
                endpoint: URL = WorkdayHolidayStore.endpoint) throws {
        self.cacheURL = cacheURL; self.transport = transport; self.endpoint = endpoint
        guard endpoint.scheme == "https", endpoint.user == nil, endpoint.password == nil,
              endpoint.query == nil, endpoint.fragment == nil else {
            throw WorkdayError.invalidData("不支持的更新入口")
        }
        for file in bundleFiles {
            let data = try Data(contentsOf: file)
            let dataset = try HolidayDataset.decode(data)
            if (years[dataset.year]?.dataset.revision ?? 0) < dataset.revision {
                years[dataset.year] = Year(dataset: dataset, downloaded: false, digest: WorkdayClock.digest(data))
            }
        }
        if FileManager.default.fileExists(atPath: cacheURL.path) {
            do {
                let data = try Data(contentsOf: cacheURL)
                guard data.count <= 3 * 1024 * 1024 else { throw WorkdayError.invalidData("缓存过大") }
                let saved = try JSONDecoder().decode(Cache.self, from: data)
                guard saved.schemaVersion == 1, saved.files.count <= 16 else {
                    throw WorkdayError.invalidData("缓存版本不支持")
                }
                for (key, raw) in saved.files {
                    let value = try HolidayDataset.decode(raw)
                    guard key == String(value.year) else { throw WorkdayError.invalidData("缓存年份不一致") }
                }
                cache = saved
                for raw in saved.files.values {
                    let value = try HolidayDataset.decode(raw)
                    if (years[value.year]?.dataset.revision ?? 0) < value.revision {
                        years[value.year] = Year(dataset: value, downloaded: true, digest: WorkdayClock.digest(raw))
                    }
                }
                checkedAt = cache.checkedAt; attemptedAt = cache.attemptedAt
            } catch {
                // Keep the corrupt file on disk until a successful update is available.
                warning = "下载缓存无法读取，已使用内置安排。请检查更新。"
            }
        }
    }

    @discardableResult
    public func refresh(now: Date = Date()) async throws -> Int {
        guard !isUpdating else { throw WorkdayError.network("正在检查，请稍候") }
        isUpdating = true; attemptedAt = now
        defer { isUpdating = false }
        let raw = try await transport.fetch(endpoint, maximumBytes: 64 * 1024)
        let index = try HolidayIndex.decode(raw)
        var updated = years, candidate = cache, changed = 0
        for entry in index.years {
            if let current = years[entry.year] {
                if entry.revision < current.dataset.revision { continue }
                if entry.revision == current.dataset.revision {
                    guard entry.sha256 == current.digest else {
                        throw WorkdayError.invalidData("同一版本的内容发生变化，请等待发布新版本")
                    }
                    continue
                }
            }
            let url = endpoint.deletingLastPathComponent().appendingPathComponent(entry.file)
            let data = try await transport.fetch(url, maximumBytes: 128 * 1024)
            guard WorkdayClock.digest(data) == entry.sha256 else { throw WorkdayError.invalidData("文件校验不一致") }
            let value = try HolidayDataset.decode(data)
            guard value.year == entry.year, value.revision == entry.revision else {
                throw WorkdayError.invalidData("文件与索引不一致")
            }
            candidate.files[String(entry.year)] = data
            updated[entry.year] = Year(dataset: value, downloaded: true, digest: entry.sha256)
            changed += 1
        }
        // Retain only a bounded number of downloaded years, newest first.
        let retained = Set(candidate.files.keys.sorted().suffix(16))
        candidate.files = candidate.files.filter { retained.contains($0.key) }
        candidate.checkedAt = now; candidate.attemptedAt = now
        try WorkdayPersistence.write(candidate, to: cacheURL)
        cache = candidate; years = updated; checkedAt = now; warning = nil
        return changed
    }
}

public enum WorkdayPersistence {
    public static func write<T: Encodable>(_ value: T, to url: URL) throws {
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
#if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                             ofItemAtPath: url.path)
#endif
    }
}
