import Foundation

/// Plain-text G-code from PrusaSlicer, OrcaSlicer, Bambu Studio, Cura:
/// embedded thumbnails and slicer comments. No toolpath rendering (yet).
enum GCodeLoader {
    /// Reads the head and tail of the file where slicers put thumbnails and settings.
    private static func text(_ url: URL) -> String {
        guard let h = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: 0)
        let headLen = min(size, 2_000_000)
        var data = (try? h.read(upToCount: Int(headLen))) ?? Data()
        if size > headLen {
            let tailStart = max(headLen, size - 256_000)
            try? h.seek(toOffset: tailStart)
            data.append(contentsOf: "\n".utf8)
            data.append((try? h.readToEnd()) ?? Data())
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// PNG/JPG thumbnails, smallest first.
    static func thumbnails(_ url: URL) -> [Data] {
        thumbnails(in: text(url))
    }

    private static func thumbnails(in text: String) -> [Data] {
        var out: [(Int, Data)] = []
        var b64 = ""
        var collecting = false
        var area = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let l = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard l.hasPrefix(";") else { if collecting { collecting = false }; continue }
            let body = l.dropFirst().trimmingCharacters(in: .whitespaces)
            if body.hasPrefix("thumbnail") && body.contains(" begin") {
                // "; thumbnail begin 300x300 12345" / "thumbnail_JPG begin ..." (QOI isn't decodable here)
                collecting = !body.hasPrefix("thumbnail_QOI")
                b64 = ""
                let dims = body.split(separator: " ").first { $0.contains("x") }?.split(separator: "x").compactMap { Int($0) } ?? []
                area = dims.count == 2 ? dims[0] * dims[1] : 0
            } else if body.hasPrefix("thumbnail") && body.contains(" end") {
                if collecting, let d = Data(base64Encoded: b64) { out.append((area, d)) }
                collecting = false
            } else if collecting {
                b64 += body
            }
        }
        return out.sorted { $0.0 < $1.0 }.map(\.1)
    }

    static func load(_ url: URL) throws -> ThreeMFModel {
        let t = text(url)
        var kv: [String: String] = [:]
        for line in t.split(separator: "\n") where line.hasPrefix(";") {
            let body = line.dropFirst().trimmingCharacters(in: .whitespaces)
            guard let sep = body.firstIndex(where: { $0 == "=" || $0 == ":" }) else { continue }
            let k = body[..<sep].trimmingCharacters(in: .whitespaces).lowercased()
            let v = body[body.index(after: sep)...].trimmingCharacters(in: .whitespaces)
            if !k.isEmpty, !v.isEmpty, kv[k] == nil { kv[k] = v }
        }
        func first(_ keys: [String]) -> String? { keys.lazy.compactMap { kv[$0] }.first }
        func firstOfList(_ s: String?) -> String? {
            s?.split(whereSeparator: { $0 == ";" || $0 == "," }).first.map { $0.trimmingCharacters(in: .whitespaces) }
        }

        var m = ThreeMFModel()
        m.info.title = url.deletingPathExtension().lastPathComponent
        m.info.printer = first(["printer_model", "printer_settings_id"])?.replacingOccurrences(of: "\"", with: "")
        if let n = firstOfList(first(["nozzle_diameter"])) { m.info.nozzle = "\(n) mm" }
        if let l = first(["layer_height", "layer height"]) { m.info.layerHeight = "\(l) mm" }
        if let f = first(["sparse_infill_density", "fill_density", "infill_sparse_density"]) { m.info.infill = f }
        if let types = first(["filament_type", "filament type"]) {
            var seen: [String] = []
            for t in types.split(whereSeparator: { $0 == ";" || $0 == "," }).map({ $0.trimmingCharacters(in: .whitespaces) })
            where !t.isEmpty && !seen.contains(t) { seen.append(t) }
            m.info.filaments = seen
        }
        // Time: "1d 2h 3m 4s" (Prusa/Orca), "2h3m" (Bambu), or seconds (Cura ";TIME:1234")
        if let time = first(["estimated printing time (normal mode)", "total estimated time", "model printing time", "time"]) {
            m.info.printTime = parseDuration(time).map(Format.duration) ?? time
        }
        if let g = first(["filament used [g]", "total filament weight [g]", "total filament used [g]"]),
           let grams = g.split(whereSeparator: { $0 == "," || $0 == ";" }).compactMap({ Double($0.trimmingCharacters(in: .whitespaces)) })
            .reduce(Optional<Double>.none, { ($0 ?? 0) + $1 }) {
            m.info.filamentWeight = Format.grams(grams)
        }
        let image = thumbnails(in: t).last
        m.sliced = [SlicedPlate(name: m.info.title ?? "G-code", image: image, seconds: nil, grams: nil)]
        m.thumbnail = image
        if let data = try? Data(contentsOf: url, options: .alwaysMapped) {
            let tp = Toolpath.parse(data)
            if !tp.vertices.isEmpty { m.toolpath = tp }
        }
        return m
    }

    static func parseDuration(_ s: String) -> Int? {
        if let n = Int(s) { return n }
        var total = 0, num = 0, any = false
        for ch in s {
            if let d = ch.wholeNumberValue { num = num * 10 + d; continue }
            switch ch {
            case "d": total += num * 86400; any = true
            case "h": total += num * 3600; any = true
            case "m": total += num * 60; any = true
            case "s": total += num; any = true
            default: break
            }
            if ch.isLetter { num = 0 }
        }
        return any ? total : nil
    }
}
