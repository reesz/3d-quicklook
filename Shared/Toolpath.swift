import Foundation
import simd

/// Extrusion moves from G-code as line segments, grouped by layer and colored by feature.
struct Toolpath {
    var vertices: [SIMD3<Float>] = []     // 2 per segment
    var colors: [SIMD3<Float>] = []       // per vertex
    var layerEnds: [Int] = []             // segment count at the end of each layer
    var features: [String] = []           // feature names seen, in order

    static let maxSegments = 3_000_000

    /// Byte-level parser: G0/G1/G2/G3 (arcs as chords), G90/G91, M82/M83, G92, ;TYPE: / ; FEATURE: comments.
    static func parse(_ data: Data) -> Toolpath {
        var tp = Toolpath()
        var pos = SIMD4<Double>(0, 0, 0, 0)        // x y z e
        var absXYZ = true, absE = true
        var color = SIMD3<Float>(0.6, 0.6, 0.6)
        var layerZ = -Double.infinity
        var stride = 1, counter = 0
        // Rough size guess to thin out huge files instead of running out of memory.
        let estimate = data.count / 30
        if estimate > maxSegments { stride = Int((Double(estimate) / Double(maxSegments)).rounded(.up)) }

        data.withUnsafeBytes { raw in
            let p = raw.bindMemory(to: UInt8.self).baseAddress!
            let n = raw.count
            var i = 0
            func num(_ j: inout Int) -> Double {
                var s = j
                while s < n, p[s] == 32 { s += 1 }
                var neg = false
                if s < n, p[s] == 45 { neg = true; s += 1 } else if s < n, p[s] == 43 { s += 1 }
                var v = 0.0, frac = 0.0, div = 1.0, seenDot = false
                while s < n {
                    let c = p[s]
                    if c >= 48 && c <= 57 {
                        if seenDot { div *= 10; frac = frac * 10 + Double(c - 48) } else { v = v * 10 + Double(c - 48) }
                    } else if c == 46 && !seenDot { seenDot = true } else { break }
                    s += 1
                }
                j = s
                let r = v + frac / div
                return neg ? -r : r
            }
            while i < n {
                // line bounds
                var e = i
                while e < n, p[e] != 10 { e += 1 }
                defer { i = e + 1 }
                var s = i
                while s < e, p[s] == 32 || p[s] == 9 { s += 1 }
                guard s < e else { continue }
                if p[s] == 59 {                                         // comment: feature tags
                    let line = String(decoding: UnsafeBufferPointer(start: p + s + 1, count: min(e - s - 1, 60)), as: UTF8.self)
                        .trimmingCharacters(in: .whitespaces)
                    let upper = line.uppercased()
                    for tag in ["TYPE:", "FEATURE:"] where upper.hasPrefix(tag) {
                        let name = line.dropFirst(tag.count).trimmingCharacters(in: .whitespacesAndNewlines)
                        color = featureColor(name)
                        if !tp.features.contains(name) { tp.features.append(name) }
                    }
                    continue
                }
                let cmd = p[s]
                guard cmd == 71 || cmd == 77 else { continue }          // 'G' / 'M'
                var j = s + 1
                let code = Int(num(&j))
                if cmd == 77 {
                    if code == 82 { absE = true } else if code == 83 { absE = false }
                    continue
                }
                switch code {
                case 90: absXYZ = true; absE = true; continue
                case 91: absXYZ = false; absE = false; continue
                case 92:
                    while j < e, p[j] != 59 {
                        if p[j] == 69 { j += 1; pos.w = num(&j) } else { j += 1 }
                    }
                    continue
                case 0, 1, 2, 3: break
                default: continue
                }
                var target = pos
                var hasE = false
                while j < e, p[j] != 59 {
                    let c = p[j] & ~0x20                                // uppercase
                    if c == 88 || c == 89 || c == 90 || c == 69 {
                        j += 1
                        let v = num(&j)
                        switch c {
                        case 88: target.x = absXYZ ? v : pos.x + v
                        case 89: target.y = absXYZ ? v : pos.y + v
                        case 90: target.z = absXYZ ? v : pos.z + v
                        default: target.w = absE ? v : pos.w + v; hasE = true
                        }
                    } else { j += 1 }
                }
                let extruding = hasE && target.w > pos.w + 1e-6 && (target.x != pos.x || target.y != pos.y)
                if extruding {
                    if target.z > layerZ + 1e-4 {
                        if !tp.vertices.isEmpty { tp.layerEnds.append(tp.vertices.count / 2) }
                        layerZ = target.z
                    }
                    counter += 1
                    if counter % stride == 0 {
                        tp.vertices.append(SIMD3(Float(pos.x), Float(pos.y), Float(pos.z)))
                        tp.vertices.append(SIMD3(Float(target.x), Float(target.y), Float(target.z)))
                        tp.colors.append(color); tp.colors.append(color)
                    }
                }
                pos = target
            }
        }
        if !tp.vertices.isEmpty { tp.layerEnds.append(tp.vertices.count / 2) }
        // drop empty layers produced by thinning
        var dedup: [Int] = []
        for l in tp.layerEnds where dedup.last != l { dedup.append(l) }
        tp.layerEnds = dedup
        return tp
    }

    static func featureColor(_ name: String) -> SIMD3<Float> {
        let n = name.lowercased()
        func c(_ hex: UInt32) -> SIMD3<Float> {
            SIMD3(Float(hex >> 16 & 0xFF) / 255, Float(hex >> 8 & 0xFF) / 255, Float(hex & 0xFF) / 255)
        }
        if n.contains("outer") || n.contains("external") || n == "wall-outer" { return c(0xFF8A1E) }
        if n.contains("overhang") { return c(0x2F7FFF) }
        if n.contains("bridge") { return c(0x4D9BF0) }
        if n.contains("support") { return c(0x3FB06A) }
        if n.contains("skirt") || n.contains("brim") { return c(0x3CC0C0) }
        if n.contains("top") { return c(0xF0436B) }
        if n.contains("bottom") { return c(0x8A63F0) }
        if n.contains("solid") || n == "skin" { return c(0xA44FE0) }
        if n.contains("infill") || n == "fill" { return c(0xC9473C) }
        if n.contains("gap") { return c(0xE8E8E8) }
        if n.contains("wall") || n.contains("perimeter") { return c(0xFFCF3F) }
        if n.contains("ironing") { return c(0xF5A0B0) }
        return c(0x9A9A9A)
    }
}
