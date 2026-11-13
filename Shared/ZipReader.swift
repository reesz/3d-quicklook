import Foundation
import Compression

/// Minimal read-only ZIP reader (stored + deflate), enough for 3MF packages.
struct ZipReader {
    struct Entry {
        let name: String
        let method: UInt16
        let compressedSize: Int
        let uncompressedSize: Int
        let localHeaderOffset: Int
    }

    enum ZipError: Error { case notZip, unsupported(String), corrupt }

    let data: Data
    private(set) var entries: [String: Entry] = [:]

    init(url: URL) throws {
        data = try Data(contentsOf: url, options: .alwaysMapped)
        try readCentralDirectory()
    }

    private func u16(_ o: Int) -> Int { Int(data[data.startIndex + o]) | Int(data[data.startIndex + o + 1]) << 8 }
    private func u32(_ o: Int) -> Int { u16(o) | u16(o + 2) << 16 }
    private func u64(_ o: Int) -> Int { u32(o) | u32(o + 4) << 32 }

    private mutating func readCentralDirectory() throws {
        let n = data.count
        guard n >= 22 else { throw ZipError.notZip }
        var eocd = -1
        var i = n - 22
        let stop = max(0, n - 22 - 65_535)
        while i >= stop {
            if u32(i) == 0x0605_4b50 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { throw ZipError.notZip }
        var count = u16(eocd + 10)
        var cdOffset = u32(eocd + 16)

        // Zip64 end of central directory
        if (cdOffset == 0xFFFF_FFFF || count == 0xFFFF), eocd >= 20, u32(eocd - 20) == 0x0706_4b50 {
            let z64 = u64(eocd - 20 + 8)
            if z64 + 56 <= n, u32(z64) == 0x0606_4b50 {
                count = u64(z64 + 32)
                cdOffset = u64(z64 + 48)
            }
        }

        var p = cdOffset
        for _ in 0..<count {
            guard p + 46 <= n, u32(p) == 0x0201_4b50 else { throw ZipError.corrupt }
            let method = UInt16(u16(p + 10))
            var csize = u32(p + 20)
            var usize = u32(p + 24)
            let nameLen = u16(p + 28), extraLen = u16(p + 30), commentLen = u16(p + 32)
            var local = u32(p + 42)
            let nameData = data.subdata(in: (data.startIndex + p + 46)..<(data.startIndex + p + 46 + nameLen))
            let name = String(decoding: nameData, as: UTF8.self)

            // Zip64 extra field
            var e = p + 46 + nameLen
            let eEnd = e + extraLen
            while e + 4 <= eEnd {
                let id = u16(e), size = u16(e + 2)
                if id == 0x0001 {
                    var q = e + 4
                    if usize == 0xFFFF_FFFF { usize = u64(q); q += 8 }
                    if csize == 0xFFFF_FFFF { csize = u64(q); q += 8 }
                    if local == 0xFFFF_FFFF { local = u64(q); q += 8 }
                }
                e += 4 + size
            }

            entries[name] = Entry(name: name, method: method, compressedSize: csize,
                                  uncompressedSize: usize, localHeaderOffset: local)
            p += 46 + nameLen + extraLen + commentLen
        }
    }

    /// Case-insensitive lookup, tolerant of a leading slash.
    func entry(named path: String) -> Entry? {
        var p = path
        while p.hasPrefix("/") { p.removeFirst() }
        if let e = entries[p] { return e }
        let lower = p.lowercased()
        return entries.first { $0.key.lowercased() == lower }?.value
    }

    func read(_ path: String) throws -> Data? {
        guard let e = entry(named: path) else { return nil }
        return try read(e)
    }

    func read(_ e: Entry) throws -> Data {
        let lh = e.localHeaderOffset
        guard u32(lh) == 0x0403_4b50 else { throw ZipError.corrupt }
        let start = lh + 30 + u16(lh + 26) + u16(lh + 28)
        guard start + e.compressedSize <= data.count else { throw ZipError.corrupt }
        let range = (data.startIndex + start)..<(data.startIndex + start + e.compressedSize)

        switch e.method {
        case 0:
            return data.subdata(in: range)
        case 8:
            var out = Data(count: e.uncompressedSize)
            let written = out.withUnsafeMutableBytes { dst -> Int in
                data.withUnsafeBytes { src -> Int in
                    let s = src.baseAddress!.advanced(by: range.lowerBound - data.startIndex)
                    return compression_decode_buffer(
                        dst.bindMemory(to: UInt8.self).baseAddress!, e.uncompressedSize,
                        s.assumingMemoryBound(to: UInt8.self), e.compressedSize,
                        nil, COMPRESSION_ZLIB)
                }
            }
            guard written == e.uncompressedSize || e.uncompressedSize == 0 else { throw ZipError.corrupt }
            return out
        default:
            throw ZipError.unsupported("compression method \(e.method)")
        }
    }
}
