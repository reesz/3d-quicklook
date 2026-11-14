import Foundation
import Compression

/// Prusa binary G-code (.bgcode): thumbnails + metadata blocks.
/// G-code blocks (heatshrink + MeatPack) aren't decoded, so no toolpath for this format.
enum BGCodeLoader {
    private struct Block { let type: Int; let params: Data; let payload: Data; let compression: Int; let size: Int }

    private static func blocks(_ data: Data) -> [Block] {
        guard data.count > 10, data.prefix(4) == Data("GCDE".utf8) else { return [] }
        func u16(_ o: Int) -> Int { Int(data[data.startIndex + o]) | Int(data[data.startIndex + o + 1]) << 8 }
        func u32(_ o: Int) -> Int { u16(o) | u16(o + 2) << 16 }
        let crc = u16(8) == 1 ? 4 : 0
        var o = 10
        var out: [Block] = []
        while o + 8 <= data.count {
            let type = u16(o), comp = u16(o + 2), usize = u32(o + 4)
            var hdr = 8, csize = usize
            if comp != 0 { guard o + 12 <= data.count else { break }; csize = u32(o + 8); hdr = 12 }
            let paramLen = type == 5 ? 6 : 2
            let ps = o + hdr, ds = ps + paramLen, de = ds + csize
            guard de + crc <= data.count else { break }
            // Only keep what we need; G-code blocks can be huge.
            if type != 1 {
                out.append(Block(type: type, params: data.subdata(in: (data.startIndex + ps)..<(data.startIndex + ds)),
                                 payload: data.subdata(in: (data.startIndex + ds)..<(data.startIndex + de)),
                                 compression: comp, size: usize))
            }
            o = de + crc
        }
        return out
    }

    /// PNG/JPG thumbnails, smallest first (QOI skipped).
    static func thumbnails(_ url: URL) -> [Data] {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return [] }
        return blocks(data).filter { $0.type == 5 && $0.compression == 0 }
            .compactMap { b -> (Int, Data)? in
                let fmt = Int(b.params[b.params.startIndex]) | Int(b.params[b.params.startIndex + 1]) << 8
                guard fmt != 2 else { return nil }
                let w = Int(b.params[b.params.startIndex + 2]) | Int(b.params[b.params.startIndex + 3]) << 8
                let h = Int(b.params[b.params.startIndex + 4]) | Int(b.params[b.params.startIndex + 5]) << 8
                return (w * h, b.payload)
            }
            .sorted { $0.0 < $1.0 }.map(\.1)
    }

    private static func inflate(_ d: Data, size: Int) -> Data? {
        guard d.count > 2 else { return nil }
        let body = d.dropFirst(2)                        // zlib header → raw deflate
        var out = Data(count: size)
        let n = out.withUnsafeMutableBytes { dst in
            body.withUnsafeBytes { src in
                compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, size,
                                          src.bindMemory(to: UInt8.self).baseAddress!, body.count, nil, COMPRESSION_ZLIB)
            }
        }
        return n > 0 ? out.prefix(n) : nil
    }

    static func load(_ url: URL) throws -> ThreeMFModel {
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        var kv: [String: String] = [:]
        for b in blocks(data) where (0...4).contains(b.type) {
            let text: Data?
            switch b.compression {
            case 0: text = b.payload
            case 1: text = inflate(b.payload, size: b.size)
            default: text = nil                          // heatshrink metadata: rare, skipped
            }
            guard let t = text else { continue }
            for line in String(decoding: t, as: UTF8.self).split(whereSeparator: \.isNewline) {
                guard let eq = line.firstIndex(of: "=") else { continue }
                let k = line[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
                if kv[k] == nil { kv[k] = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces) }
            }
        }
        var m = ThreeMFModel()
        m.info.title = url.deletingPathExtension().lastPathComponent
        m.info.printer = kv["printer_model"]
        if let n = kv["nozzle_diameter"]?.split(separator: ",").first { m.info.nozzle = "\(n) mm" }
        if let l = kv["layer_height"] { m.info.layerHeight = "\(l) mm" }
        if let f = kv["fill_density"] ?? kv["sparse_infill_density"] { m.info.infill = f }
        if let t = kv["filament_type"] {
            var seen: [String] = []
            for x in t.split(whereSeparator: { $0 == ";" || $0 == "," }).map({ $0.trimmingCharacters(in: .whitespaces) })
            where !seen.contains(x) { seen.append(x) }
            m.info.filaments = seen
        }
        if let t = kv["estimated printing time (normal mode)"] {
            m.info.printTime = GCodeLoader.parseDuration(t).map(Format.duration) ?? t
        }
        if let g = kv["filament used [g]"], let v = Double(g.split(separator: ",").first ?? "") {
            m.info.filamentWeight = Format.grams(v)
        }
        let image = thumbnails(url).last
        m.thumbnail = image
        m.sliced = [SlicedPlate(name: m.info.title ?? "G-code", image: image)]
        return m
    }
}
