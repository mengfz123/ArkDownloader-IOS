import Foundation

/// Baidu PCS/CDN direct-link helpers, ported from the Android version.
/// Filename note: Baidu fin= is usually UTF-8 percent-encoded.
enum UrlResolve {
    private static let baiduHostMarkers = [
        "baidupcs.com", "antpcdn.com", "jomodns.com", "pcs.baidu.com"
    ]

    private static let illegalFileChars = CharacterSet(charactersIn: "\\/:*?\"<>|\u{0000}...\u{001F}")
    private static let illegalPathSegmentChars = CharacterSet(charactersIn: ":*?\"<>|\u{0000}...\u{001F}")

    static func normalizeUrl(_ url: String) -> String {
        url.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "htype=&randtype=", with: "htype&randtype")
    }

    static func isBaiduUrl(_ url: String) -> Bool {
        let u = url.lowercased()
        guard baiduHostMarkers.contains(where: { u.contains($0) }) else { return false }
        return u.contains("size=") && u.contains("/file/")
    }

    static func parseBaiduSize(_ url: String) -> Int64 {
        guard let raw = rawQueryParam(url, "size"), let v = Int64(raw), v > 0 else { return 0 }
        return v
    }

    static func parseFin(_ url: String) -> String {
        guard let raw = rawQueryParam(url, "fin") else { return "" }
        return sanitizeFileName(decodeEncodedName(raw))
    }

    static func resolveHttpFileName(_ url: String, contentDisposition: String? = nil, nameHint: String? = nil) -> String {
        canonicalFileName(url, contentDisposition: contentDisposition, nameHint: nameHint)
    }

    static func canonicalFileName(_ url: String, contentDisposition: String? = nil, nameHint: String? = nil) -> String {
        let hintClean: String? = {
            guard let hint = nameHint, !hint.isEmpty else { return nil }
            let decoded = sanitizeRelativeFileName(decodeEncodedName(hint))
            return decoded
        }()

        if isBaiduUrl(url) {
            let fin = parseFin(url)
            let (hintDir, hintFile) = splitRelativeDownloadPath(hintClean)
            let leaf: String
            if !fin.isEmpty && !looksGarbled(fin) {
                if hintClean == nil || looksGarbled(hintFile) ||
                    scoreName(fin) + 8 >= scoreName(hintFile.isEmpty ? hintClean ?? "" : hintFile) {
                    leaf = fin
                } else {
                    leaf = hintFile.isEmpty ? (hintClean ?? "") : hintFile
                }
            } else if let hc = hintClean, !hc.isEmpty {
                leaf = hintFile.isEmpty ? hc : hintFile
            } else {
                leaf = "baidu_download.bin"
            }
            return joinRelative(hintDir, leaf)
        }

        var candidates = [String]()
        if isQuarkOrCdnUrl(url) {
            if let n = extractNameFromHttpUrl(url), !n.isEmpty && n != "download.bin" {
                candidates.append(n)
            }
        }
        if let n = parseContentDispositionName(contentDisposition) { candidates.append(n) }
        if let n = extractNameFromHttpUrl(url) { candidates.append(n) }
        let inferred = inferFileName(url, fallback: "")
        if !inferred.isEmpty && inferred != "download.bin" { candidates.append(inferred) }
        if let hc = hintClean { candidates.append(hc) }

        let good = candidates.filter { !$0.isEmpty && !looksGarbled($0) && $0 != "download.bin" }
        if !good.isEmpty {
            let best = good.max { scoreName($0) < scoreName($1) } ?? good[0]
            let (hintDir, _) = splitRelativeDownloadPath(hintClean)
            let (chosenDir, chosenFile) = splitRelativeDownloadPath(best)
            return joinRelative(chosenDir.isEmpty ? hintDir : chosenDir, chosenFile)
        }
        if let hc = hintClean, !hc.isEmpty { return hc }
        return "download.bin"
    }

    private static func joinRelative(_ dir: String?, _ file: String) -> String {
        let leaf = sanitizeFileName(file.isEmpty ? "download.bin" : file)
        guard let d = dir?.replacingOccurrences(of: "\\", with: "/").trimmingCharacters(in: CharacterSet(charactersIn: "/")), !d.isEmpty else {
            return leaf
        }
        return "\(d)/\(leaf)"
    }

    static func isQuarkOrCdnUrl(_ url: String) -> Bool {
        let u = url.lowercased()
        return ["quark.cn", "myqcloud.com", "aliyuncs.com", "qcloud.com",
                "drive.quark", "response-content-disposition=", "x-oss-meta-filename="]
            .contains { u.contains($0) }
    }

    static func displayFileName(_ stored: String?, _ url: String) -> String {
        if let s = stored?.replacingOccurrences(of: "\\", with: "/").trimmingCharacters(in: CharacterSet(charactersIn: "/")),
           !s.isEmpty, s.contains("/"), !looksGarbled(s) {
            return s
        }
        return canonicalFileName(url, contentDisposition: nil, nameHint: stored)
    }

    static func inferFileName(_ url: String, fallback: String = "download.bin") -> String {
        if isBaiduUrl(url) {
            let fin = parseFin(url)
            if !fin.isEmpty { return fin }
            return "baidu_download.bin"
        }
        do {
            let pathSeg = String(url.split(separator: "?")[0].split(separator: "/").last ?? "")
            let decoded = decodeEncodedName(pathSeg)
            if !decoded.isEmpty && decoded.contains(".") {
                return sanitizeFileName(decoded)
            }
        }
        return fallback
    }

    static func resolve(_ url: String, nameHint: String? = nil, sizeHint: Int64 = 0) -> ResolvedUrl {
        let normalized = normalizeUrl(url)
        if isBaiduUrl(normalized) {
            let size = parseBaiduSize(normalized) > 0 ? parseBaiduSize(normalized) : sizeHint
            if size <= 0 {
                fatalError("百度直链缺少 size= 参数")
            }
            let name = canonicalFileName(normalized, nameHint: nameHint)
            return ResolvedUrl(url: normalized, size: size, name: name, kind: .baidu)
        }
        let name = canonicalFileName(normalized, nameHint: nameHint)
        return ResolvedUrl(url: normalized, size: max(sizeHint, 0), name: name, kind: .http)
    }

    static func pickUserAgent(_ kind: Kind, _ settings: AppSettings, override: String? = nil) -> String {
        if let ov = override, !ov.isEmpty { return ov }
        switch kind {
        case .baidu:
            return settings.userAgent.isEmpty ? AppSettings.baiduUA : settings.userAgent
        case .http:
            return settings.httpUserAgent.isEmpty ? AppSettings.defaultHttpUserAgent : settings.httpUserAgent
        }
    }

    static func pickUserAgent(_ url: String, _ settings: AppSettings, override: String? = nil) -> String {
        let kind: Kind = isBaiduUrl(url) ? .baidu : .http
        return pickUserAgent(kind, settings, override: override)
    }

    static func chunkBytes(_ chunkSizeMbOrBytes: Int, _ kind: Kind) -> Int {
        let bytes: Int
        if chunkSizeMbOrBytes <= AppSettings.maxChunkMb {
            bytes = AppSettings.chunkBytesFromMb(chunkSizeMbOrBytes)
        } else {
            bytes = chunkSizeMbOrBytes.clamped(to: AppSettings.minChunk...AppSettings.maxChunk)
        }
        return kind == .baidu ? min(bytes, AppSettings.chunkBaidu) : bytes
    }

    static func decodeEncodedName(_ raw: String) -> String {
        if raw.isEmpty { return "" }
        var candidate = raw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "+", with: " ")
        for _ in 0..<3 {
            if !candidate.contains("%") { break }
            let once = percentDecodeToStringBest(candidate)
            if once == candidate { break }
            candidate = once
        }
        if candidate.contains("%") {
            candidate = percentDecodeToStringBest(candidate)
        } else if looksGarbled(candidate) {
            candidate = pickBestName(candidate,
                repairMojibake(candidate, .utf8),
                repairMojibake(candidate, Self.encodingForCharset("GB18030")),
                repairMojibake(candidate, Self.encodingForCharset("GBK")))
        }
        return candidate.trimmingCharacters(in: .whitespaces)
    }

    static func sanitizeFileName(_ name: String) -> String {
        var n = name.trimmingCharacters(in: .whitespaces)
        n = n.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        n = n.components(separatedBy: illegalFileChars).joined(separator: "_")
        if n.isEmpty || n == "." || n == ".." { return "download.bin" }
        let base = n.split(separator: ".").dropLast().joined(separator: ".")
        let reserved = ["CON", "PRN", "AUX", "NUL"]
        if reserved.contains(base.uppercased()) { n = "_\(n)" }
        return String(n.prefix(200))
    }

    static func splitRelativeDownloadPath(_ raw: String?) -> (String, String) {
        guard let raw = raw, !raw.isEmpty else { return ("", "download.bin") }
        var n = decodeEncodedName(raw.trimmingCharacters(in: .whitespaces))
            .replacingOccurrences(of: "\\", with: "/")
        while n.contains("//") { n = n.replacingOccurrences(of: "//", with: "/") }
        n = n.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if n.isEmpty { return ("", "download.bin") }
        if n.hasPrefix("/") || Self.regexRange(in: n, pattern: #"^[A-Za-z]:/"#) != nil {
            return ("", sanitizeFileName(n.split(separator: "/").last.map(String.init) ?? n))
        }
        let parts = n.split(separator: "/").map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0 != "." }
        if parts.isEmpty || parts.contains("..") {
            return ("", sanitizeFileName(n.split(separator: "/").last.map(String.init) ?? n))
        }
        let file = sanitizeFileName(parts.last!)
        if parts.count == 1 { return ("", file) }
        let parent = parts.dropLast().map { sanitizePathSegment($0) }.joined(separator: "/")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return (parent, file)
    }

    static func sanitizePathSegment(_ name: String) -> String {
        var n = name.trimmingCharacters(in: .whitespaces)
        n = n.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        n = n.components(separatedBy: illegalPathSegmentChars).joined(separator: "_")
        n = n.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "\\", with: "_")
        if n.isEmpty || n == "." || n == ".." { return "folder" }
        let reserved = ["CON", "PRN", "AUX", "NUL"]
        if reserved.contains(n.uppercased()) { n = "_\(n)" }
        return String(n.prefix(80))
    }

    static func sanitizeRelativeFileName(_ name: String) -> String {
        let (parent, file) = splitRelativeDownloadPath(name)
        return parent.isEmpty ? file : "\(parent)/\(file)"
    }

    static func parseContentDispositionName(_ header: String?) -> String? {
        guard let header = header, !header.isEmpty else { return nil }
        let hd = header.contains("%") && header.lowercased().contains("filename")
            ? decodeEncodedName(header)
            : header

        if let starAny = Self.regexRange(in: hd, pattern: #"filename\*\s*=\s*([^';\s]+)\s*'\s*[^']*'\s*([^;]+)"#) {
            let match = String(hd[starAny])
            // simplified: extract charset and encoded value
            if let charsetRange = Self.regexRange(in: match, pattern: #"=\s*([^';\s]+)'"#) {
                let csName = String(match[charsetRange]).trimmingCharacters(in: CharacterSet(charactersIn: "= '\""))
                if let encRange = Self.regexRange(in: match, pattern: #"'[^']*'\s*([^;]+)$"#) {
                    let enc = String(match[encRange]).trimmingCharacters(in: CharacterSet(charactersIn: "' \""))
                    let bytes = percentDecodeToBytes(enc)
                    let encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
                        CFStringConvertIANACharSetNameToEncoding(csName as CFString)))
                    let decoded = String(data: Data(bytes), encoding: encoding)?.trimmingCharacters(in: .whitespaces) ?? ""
                    if !decoded.isEmpty && !looksGarbled(decoded) {
                        return sanitizeFileName(decoded)
                    }
                    let loose = decodeEncodedName(enc)
                    if !loose.isEmpty { return sanitizeFileName(loose) }
                }
            }
        }

        if let starUtf = Self.regexRange(in: hd, pattern: #"filename\*\s*=\s*(?:UTF-8|utf-8)''([^;]+)"#) {
            let decoded = decodeEncodedName(String(hd[starUtf]).trimmingCharacters(in: CharacterSet(charactersIn: "\"'")))
            if !decoded.isEmpty { return sanitizeFileName(decoded) }
        }

        if let plain = Self.regexRange(in: hd, pattern: #"filename\s*=\s*"([^"]*)"|filename\s*=\s*([^;\s]+)"#) {
            let full = String(hd[plain])
            var raw = full
            // extract quoted or unquoted
            if let q = full.range(of: #""[^"]*""#) {
                raw = String(full[q]).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            } else if let eq = full.range(of: "=") {
                raw = String(full[eq.upperBound...]).trimmingCharacters(in: .whitespaces)
            }
            if raw.contains("%") {
                let decoded = decodeEncodedName(raw)
                if !decoded.isEmpty && !looksGarbled(decoded) {
                    return sanitizeFileName(decoded)
                }
            }
            if !raw.isEmpty { return sanitizeFileName(raw) }
        }
        return nil
    }

    static func extractNameFromHttpUrl(_ url: String) -> String? {
        let keys = ["response-content-disposition", "x-oss-meta-filename", "filename",
                    "fileName", "file_name", "fname", "attname", "download", "name"]
        var candidates = [String]()
        for key in keys {
            guard let raw = rawQueryParam(url, key) else { continue }
            let once = decodeEncodedName(raw)
            let twice = once.contains("%") ? decodeEncodedName(once) : once
            for blob in [twice, once, raw.replacingOccurrences(of: "+", with: " ")] {
                let lower = blob.lowercased()
                if lower.contains("filename") || lower.contains("attachment") || lower.contains("inline") {
                    if let n = parseContentDispositionName(blob) { candidates.append(n) }
                }
                let asName = sanitizeFileName(blob)
                if asName.contains(".") && !looksGarbled(asName) && asName != "download.bin"
                    && !asName.contains("=") && (3...180).contains(asName.count) {
                    candidates.append(asName)
                }
            }
        }
        let pathSeg = String(url.split(separator: "?")[0].split(separator: "/").last ?? "")
        if !pathSeg.isEmpty && (pathSeg.contains(".") || pathSeg.contains("%")) {
            let decoded = decodeEncodedName(pathSeg)
            if !decoded.isEmpty && !looksGarbled(decoded) && decoded.contains(".") {
                candidates.append(sanitizeFileName(decoded))
            }
        }
        let good = candidates.filter { !looksGarbled($0) && $0 != "download.bin" }
        if !good.isEmpty {
            return good.max { scoreName($0) < scoreName($1) }
        }
        return candidates.max { scoreName($0) < scoreName($1) }
    }

    private static func rawQueryParam(_ url: String, _ key: String) -> String? {
        guard let q = url.firstIndex(of: "?") else { return nil }
        var query = String(url[url.index(after: q)...])
        if let hash = query.firstIndex(of: "#") {
            query = String(query[..<hash])
        }
        let marker = "\(key)="
        var from = query.startIndex
        while from < query.endIndex {
            guard let range = query.range(of: marker, options: .caseInsensitive, range: from..<query.endIndex) else { return nil }
            let idx = range.lowerBound
            let boundaryOk = idx == query.startIndex || query[query.index(before: idx)] == "&"
            if boundaryOk {
                let start = range.upperBound
                let amp = query[start...].firstIndex(of: "&") ?? query.endIndex
                let value = String(query[start..<amp])
                if !value.isEmpty { return value }
            }
            from = query.index(after: range.lowerBound)
        }
        return nil
    }

    private static func repairHeaderFileName(_ raw: String) -> String {
        if raw.isEmpty { return "" }
        if raw.contains("%") {
            let pct = decodeEncodedName(raw)
            if !pct.isEmpty && !looksGarbled(pct) { return pct }
        }
        let hasCJK = raw.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
        let allAscii = raw.unicodeScalars.allSatisfy { $0.value < 128 }
        if !looksGarbled(raw) && (hasCJK || allAscii) { return raw }
        let bytes = Data(raw.utf8)
        let utf8 = String(data: bytes, encoding: .utf8) ?? ""
        let gbk = decodeWith(bytes, encoding: "GBK")
        let gb18030 = decodeWith(bytes, encoding: "GB18030")
        if isStrictUtf8([UInt8](bytes)) && !looksGarbled(utf8) { return utf8 }
        if !looksGarbled(gb18030) && scoreName(gb18030) >= scoreName(utf8) { return gb18030 }
        if !looksGarbled(gbk) { return gbk }
        if !looksGarbled(utf8) { return utf8 }
        return pickBestName(utf8, gb18030, gbk, raw)
    }

    private static func decodeWith(_ data: Data, encoding: String) -> String {
        let cfEnc = CFStringConvertIANACharSetNameToEncoding(encoding as CFString)
        let nsEnc = CFStringConvertEncodingToNSStringEncoding(cfEnc)
        return String(data: data, encoding: String.Encoding(rawValue: nsEnc)) ?? ""
    }

    private static func encodingForCharset(_ charset: String) -> String.Encoding {
        let cfEnc = CFStringConvertIANACharSetNameToEncoding(charset as CFString)
        let nsEnc = CFStringConvertEncodingToNSStringEncoding(cfEnc)
        return String.Encoding(rawValue: nsEnc)
    }

    private static func regexRange(in string: String, pattern: String) -> Range<String.Index>? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let nsRange = NSRange(string.startIndex..., in: string)
        guard let match = regex.firstMatch(in: string, range: nsRange) else { return nil }
        return Range(match.range, in: string)
    }

    private static func percentDecodeToStringBest(_ encoded: String) -> String {
        let bytes = percentDecodeToBytes(encoded)
        if bytes.isEmpty { return encoded }
        if isStrictUtf8(bytes) {
            let utf8 = String(data: Data(bytes), encoding: .utf8) ?? ""
            if !looksGarbled(utf8) { return utf8 }
        }
        let data = Data(bytes)
        let utf8Loose = String(data: data, encoding: .utf8) ?? ""
        let gbk = decodeWith(data, encoding: "GBK")
        let gb18030 = decodeWith(data, encoding: "GB18030")
        if !isStrictUtf8(bytes) || looksGarbled(utf8Loose) {
            return pickBestName(gb18030, gbk, utf8Loose)
        }
        return utf8Loose
    }

    private static func percentDecodeToBytes(_ encoded: String) -> [UInt8] {
        manualPercentDecode(encoded.replacingOccurrences(of: "+", with: " "))
    }

    private static func manualPercentDecode(_ encoded: String) -> [UInt8] {
        var out = [UInt8]()
        var i = encoded.startIndex
        while i < encoded.endIndex {
            let c = encoded[i]
            if c == "%" {
                let next = encoded.index(after: i)
                if encoded.distance(from: next, to: encoded.endIndex) >= 2 {
                    let hex = String(encoded[next..<encoded.index(next, offsetBy: 2)])
                    if let b = UInt8(hex, radix: 16) {
                        out.append(b)
                        i = encoded.index(next, offsetBy: 2)
                        continue
                    }
                }
            }
            if c.isASCII {
                out.append(c.asciiValue ?? 0)
            } else {
                out.append(contentsOf: c.utf8)
            }
            i = encoded.index(after: i)
        }
        return out
    }

    private static func isStrictUtf8(_ bytes: [UInt8]) -> Bool {
        var decoder = UTF8()
        var iterator = bytes.makeIterator()
        while true {
            switch decoder.decode(&iterator) {
            case .scalarValue: continue
            case .emptyInput: return true
            case .error: return false
            }
        }
    }

    private static func repairMojibake(_ text: String, _ charset: String.Encoding) -> String {
        let data = text.data(using: .isoLatin1) ?? Data(text.utf8)
        return String(data: data, encoding: charset) ?? text
    }

    private static func pickBestName(_ candidates: String...) -> String {
        candidates.map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .max { scoreName($0) < scoreName($1) } ?? candidates.first ?? ""
    }

    private static func looksGarbled(_ s: String) -> Bool {
        if s.isEmpty { return true }
        if s.contains("\u{FFFD}") { return true }
        var cjk = 0, latinExt = 0, weird = 0, highLatin = 0
        for ch in s.unicodeScalars {
            let v = ch.value
            switch v {
            case 0x4E00...0x9FFF: cjk += 1
            case 0x00C0...0x024F: latinExt += 1
            case 0x80...0xFF: highLatin += 1
            case ..<0x20: weird += 1
            default: break
            }
        }
        if latinExt >= 2 && cjk == 0 { return true }
        if latinExt > cjk && latinExt >= 3 { return true }
        if highLatin >= 3 && cjk == 0 && s.contains(".") { return true }
        return false
    }

    private static func scoreName(_ s: String) -> Int {
        if s.isEmpty { return Int.min / 2 }
        var score = 0
        var cjk = 0, replacement = 0, weird = 0, latinExt = 0
        for ch in s.unicodeScalars {
            let v = ch.value
            switch v {
            case 0xFFFD: replacement += 1
            case ..<0x20: weird += 1
            case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0xF900...0xFAFF, 0xAC00...0xD7AF: cjk += 1
            case 0x00C0...0x024F: latinExt += 1
            default:
                let c = Character(ch)
                if c.isLetter || c.isNumber || "._- ()[]【】（）·、，。".contains(c) {
                    score += 1
                } else {
                    weird += 1
                }
            }
        }
        score += cjk * 8
        score -= replacement * 50
        score -= latinExt * 6
        score -= weird * 3
        if s.contains(".") { score += 5 }
        if (2...120).contains(s.count) { score += 2 }
        return score
    }

    enum Kind { case baidu, http }

    struct ResolvedUrl {
        let url: String
        let size: Int64
        let name: String
        let kind: Kind
    }
}
