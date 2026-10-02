import Foundation

/// Multi-range HTTP downloader built on URLSession.
/// Writes ranges directly into a pre-allocated file handle at absolute offsets.
final class ChunkDownloader {
    struct ProbeResult {
        let totalSize: Int64
        let supportsRange: Bool
        let statusCode: Int
        let suggestedName: String?
        let contentDisposition: String?
    }

    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.default
        config.httpMaximumConnectionsPerHost = 64
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 120
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: config)
    }

    func probe(
        url: String,
        headers: [String: String],
        userAgent: String?,
        knownSize: Int64 = -1,
        skipHead: Bool = false,
        forceHeaders: Bool = false
    ) async -> ProbeResult {
        if knownSize > 0 && !forceHeaders {
            return ProbeResult(totalSize: knownSize, supportsRange: true, statusCode: 200,
                suggestedName: nil, contentDisposition: nil)
        }
        if !skipHead {
            if let headReq = buildRequest(url: url, headers: headers, userAgent: userAgent, range: nil) {
                var req = headReq
                req.httpMethod = "HEAD"
                if let resp = try? await session.data(for: req).1 as? HTTPURLResponse,
                   (200...299).contains(resp.statusCode) {
                    let len = Int64(resp.value(forHTTPHeaderField: "Content-Length") ?? "") ?? -1
                    let result = fromResponse(resp, fallbackLen: len, knownSize: knownSize, url: url)
                    if result.totalSize > 0 || result.suggestedName != nil {
                        return result
                    }
                }
            }
        }
        let getReq = buildRequest(url: url, headers: headers, userAgent: userAgent, range: (0, 0))!
        if let resp = try? await session.data(for: getReq).1 as? HTTPURLResponse {
            return fromResponse(resp, fallbackLen: -1, knownSize: knownSize, url: url)
        }
        return ProbeResult(totalSize: -1, supportsRange: false, statusCode: 0,
            suggestedName: nil, contentDisposition: nil)
    }

    private func fromResponse(_ resp: HTTPURLResponse, fallbackLen: Int64, knownSize: Int64, url: String) -> ProbeResult {
        let cd = resp.value(forHTTPHeaderField: "Content-Disposition")
        let name = UrlResolve.resolveHttpFileName(url, contentDisposition: cd, nameHint: nil)
        let suggested = (!name.isEmpty && name != "download.bin") ? name : nil
        let len: Int64
        if fallbackLen > 0 {
            len = fallbackLen
        } else if resp.statusCode == 206 {
            len = parseContentRangeTotal(resp.value(forHTTPHeaderField: "Content-Range"))
        } else {
            len = Int64(resp.value(forHTTPHeaderField: "Content-Length") ?? "") ?? -1
        }
        let accept = resp.statusCode == 206 ||
            (resp.value(forHTTPHeaderField: "Accept-Ranges")?.lowercased().contains("bytes") ?? false)
        return ProbeResult(
            totalSize: knownSize > 0 ? knownSize : len,
            supportsRange: accept,
            statusCode: resp.statusCode,
            suggestedName: suggested,
            contentDisposition: cd
        )
    }

    /// Download [range] and write to `handle` at `writeOffset`. Returns bytes written.
    func downloadRange(
        url: String,
        range: ClosedRange<Int64>,
        handle: FileHandle,
        writeOffset: Int64,
        headers: [String: String],
        userAgent: String?,
        isCancelled: () -> Bool = { false },
        onBytes: (Int64) -> Void = { _ in }
    ) async throws -> Int64 {
        guard let req = buildRequest(url: url, headers: headers, userAgent: userAgent, range: (range.lowerBound, range.upperBound))
        else { throw NSError(domain: "ArkDownloader", code: -1, userInfo: [NSLocalizedDescriptionKey: "invalid request"]) }

        let (data, response) = try await session.data(for: req)
        if isCancelled() { throw CancellationError() }
        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode) || http.statusCode == 206 else {
            throw NSError(domain: "ArkDownloader", code: (response as? HTTPURLResponse)?.statusCode ?? -1,
                userInfo: [NSLocalizedDescriptionKey: "HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)"])
        }
        if isCancelled() { throw CancellationError() }
        try handle.seek(toOffset: UInt64(writeOffset))
        try handle.write(contentsOf: data)
        onBytes(Int64(data.count))
        return Int64(data.count)
    }

    private func buildRequest(url: String, headers: [String: String], userAgent: String?, range: (Int64, Int64)?) -> URLRequest? {
        guard let u = URL(string: url) else { return nil }
        var req = URLRequest(url: u)
        req.httpMethod = "GET"
        for (k, v) in headers {
            let key = k.lowercased()
            if key != "range" && key != "user-agent" {
                req.setValue(v, forHTTPHeaderField: k)
            }
        }
        if let ua = userAgent, !ua.isEmpty { req.setValue(ua, forHTTPHeaderField: "User-Agent") }
        req.setValue("*/*", forHTTPHeaderField: "Accept")
        req.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        req.setValue("zh-CN", forHTTPHeaderField: "Accept-Language")
        req.setValue("Keep-Alive", forHTTPHeaderField: "Connection")
        if let r = range {
            req.setValue("bytes=\(r.0)-\(r.1)", forHTTPHeaderField: "Range")
        }
        return req
    }

    private func parseContentRangeTotal(_ header: String?) -> Int64 {
        guard let h = header, !h.isEmpty else { return -1 }
        let totalPart = h.split(separator: "/").last?.split(separator: ";").first ?? ""
        return Int64(totalPart.trimmingCharacters(in: .whitespaces)) ?? -1
    }

    static func buildChunks(totalSize: Int64, chunkSize: Int) -> [ClosedRange<Int64>] {
        guard totalSize > 0 else { return [] }
        let size = max(chunkSize, 1)
        var chunks = [ClosedRange<Int64>]()
        var start: Int64 = 0
        while start < totalSize {
            let end = min(start + Int64(size) - 1, totalSize - 1)
            chunks.append(start...end)
            start = end + 1
        }
        return chunks
    }
}
