import Foundation
import simd

/// A triangle mesh with per-triangle color indices into `ThreeMFModel.palette`.
final class MeshData {
    var positions: [SIMD3<Float>] = []
    var triangles: [UInt32] = []          // 3 indices per triangle
    var triColors: [Int32] = []           // per triangle, -1 = inherit
}

struct MeshInstance {
    let mesh: MeshData
    let transform: simd_float4x4
    let defaultColor: Int32               // palette index used for triColors == -1
    let rootObject: Int                   // build item object id (used for plate grouping)
}

struct Plate {
    let index: Int            // 0-based position in the slicer's plate grid
    let name: String
    let objectIDs: Set<Int>
}

struct ModelInfo {
    var title: String?
    var designer: String?
    var printer: String?
    var nozzle: String?
    var layerHeight: String?
    var filaments: [String] = []
    var infill: String?
    var bedSize: SIMD2<Float>?    // printable area in mm
    var plateCount = 0
    var printTime: String?        // sliced files only
    var filamentWeight: String?
}

/// A sliced plate (from .gcode.3mf or G-code): preview image + slicer estimates, no mesh needed.
struct SlicedPlate {
    var name: String
    var image: Data?
    var seconds: Int?
    var grams: Double?
}

enum Format {
    static func duration(_ s: Int) -> String {
        let h = s / 3600, m = (s % 3600) / 60
        return h > 0 ? "\(h)h \(m)m" : m > 0 ? "\(m)m" : "\(s)s"
    }
    static func grams(_ g: Double) -> String { String(format: g >= 100 ? "%.0f g" : "%.1f g", g) }
}

struct ThreeMFModel {
    var palette: [SIMD4<Float>] = []
    var instances: [MeshInstance] = []
    var thumbnail: Data?
    var plates: [Plate] = []
    var info = ModelInfo()
    var sliced: [SlicedPlate] = []
    var toolpath: Toolpath?
}

enum ThreeMFError: Error { case noModel }

/// Loads a 3MF package: core spec, production extension (p:path), basematerials/colorgroups,
/// plus Bambu/Orca extruder → filament colour mapping.
final class ThreeMFLoader {
    private let zip: ZipReader
    private var palette: [SIMD4<Float>] = []
    private var paletteIndex: [SIMD4<Float>: Int32] = [:]

    private struct Component { let path: String?; let objectID: Int; let transform: simd_float4x4 }
    private struct Object {
        var mesh: MeshData?
        var components: [Component] = []
        var color: Int32 = -1
    }
    private struct ModelFile {
        var objects: [Int: Object] = [:]
        var build: [(Int, simd_float4x4)] = []
    }
    private var files: [String: ModelFile] = [:]

    // Bambu / Orca metadata
    private var filamentColors: [Int32] = []       // extruder (1-based) -> palette index
    private var objectExtruder: [Int: Int] = [:]
    private var plates: [Plate] = []
    private var info = ModelInfo()
    private var partExtruder: [Int: [Int: Int]] = [:]  // root object id -> part id -> extruder

    init(url: URL) throws { zip = try ZipReader(url: url) }

    static func load(url: URL, includeThumbnail: Bool = false) throws -> ThreeMFModel {
        try ThreeMFLoader(url: url).load(includeThumbnail: includeThumbnail)
    }

    func load(includeThumbnail: Bool) throws -> ThreeMFModel {
        loadSlicerMetadata()
        let root = findRootModelPath()
        guard let rootFile = try modelFile(root) else { throw ThreeMFError.noModel }

        var model = ThreeMFModel()
        for (objectID, t) in rootFile.build {
            var inherited: Int32 = -1
            if let ex = objectExtruder[objectID] { inherited = filamentColor(ex) }
            try instantiate(path: root, objectID: objectID, rootObject: objectID, transform: t,
                            inherited: inherited, depth: 0, into: &model.instances)
        }
        model.palette = palette
        info.plateCount = plates.count
        model.plates = plates.filter { !$0.objectIDs.isEmpty }
        loadSliceInfo(into: &model)
        model.info = info
        if includeThumbnail { model.thumbnail = findThumbnail() }
        return model
    }

    // MARK: - Instancing

    private func instantiate(path: String, objectID: Int, rootObject: Int, transform: simd_float4x4,
                             inherited: Int32, depth: Int, into out: inout [MeshInstance]) throws {
        guard depth < 16, let file = try modelFile(path), let obj = file.objects[objectID] else { return }
        var color = inherited
        if depth == 1, let ex = partExtruder[rootObject]?[objectID] {
            color = filamentColor(ex)
        } else if obj.color >= 0 && inherited < 0 {
            color = obj.color
        }
        if let mesh = obj.mesh, !mesh.triangles.isEmpty {
            out.append(MeshInstance(mesh: mesh, transform: transform, defaultColor: color, rootObject: rootObject))
        }
        for c in obj.components {
            try instantiate(path: c.path ?? path, objectID: c.objectID, rootObject: rootObject,
                            transform: transform * c.transform,
                            inherited: color, depth: depth + 1, into: &out)
        }
    }

    // MARK: - Package files

    private var rootPathCache: String?
    private func findRootModelPath() -> String {
        if let r = rootPathCache { return r }
        var result = "3D/3dmodel.model"
        if let rels = try? zip.read("_rels/.rels") {
            var found: String?
            XMLScanner.scan(rels) { tag, attrs in
                guard found == nil, tag == "Relationship",
                      let type = attrs.string("Type"), type.hasSuffix("/3dmodel"),
                      let target = attrs.string("Target") else { return }
                found = target
            }
            if let f = found { result = f }
        }
        while result.hasPrefix("/") { result.removeFirst() }
        if zip.entry(named: result) == nil,
           let any = zip.entries.keys.first(where: { $0.lowercased().hasSuffix(".model") }) {
            result = any
        }
        rootPathCache = result
        return result
    }

    private func normalize(_ p: String) -> String {
        var s = p
        while s.hasPrefix("/") { s.removeFirst() }
        return s.lowercased()
    }

    private func modelFile(_ path: String) throws -> ModelFile? {
        let key = normalize(path)
        if let f = files[key] { return f }
        guard let data = try zip.read(path) else { return nil }
        if info.title == nil, normalize(path) == normalize(findRootModelPath()) { readModelMetadata(data) }
        let f = parseModel(data)
        files[key] = f
        return f
    }

    // MARK: - Model XML

    private func parseModel(_ data: Data) -> ModelFile {
        var file = ModelFile()
        var materialGroups: [Int: [Int32]] = [:]
        var currentGroup: (Int, [Int32])?
        var currentID = 0
        var current: Object?
        var mesh: MeshData?
        var inBuild = false

        XMLScanner.scan(data, onEnd: { tag in
            switch tag {
            case "object":
                if let o = current { file.objects[currentID] = o }
                current = nil; mesh = nil
            case "basematerials", "colorgroup":
                if let g = currentGroup { materialGroups[g.0] = g.1 }
                currentGroup = nil
            case "build": inBuild = false
            default: break
            }
        }) { tag, a in
            switch tag {
            case "vertex":
                mesh?.positions.append(SIMD3(a.float("x"), a.float("y"), a.float("z")))
            case "triangle":
                guard let m = mesh else { return }
                m.triangles.append(UInt32(a.int("v1") ?? 0))
                m.triangles.append(UInt32(a.int("v2") ?? 0))
                m.triangles.append(UInt32(a.int("v3") ?? 0))
                var c: Int32 = -1
                if let pid = a.int("pid"), let group = materialGroups[pid] {
                    let idx = a.int("p1") ?? 0
                    if idx < group.count { c = group[idx] }
                }
                m.triColors.append(c)
            case "object":
                currentID = a.int("id") ?? 0
                var o = Object()
                if let pid = a.int("pid"), let group = materialGroups[pid] {
                    let idx = a.int("pindex") ?? 0
                    if idx < group.count { o.color = group[idx] }
                }
                current = o
            case "mesh":
                let m = MeshData()
                mesh = m
                current?.mesh = m
            case "component":
                guard let id = a.int("objectid") else { return }
                current?.components.append(Component(path: a.string("path"), objectID: id,
                                                      transform: Self.transform(a.string("transform"))))
            case "build": inBuild = true
            case "item":
                guard inBuild, let id = a.int("objectid") else { return }
                if a.string("printable") == "0" { return }
                file.build.append((id, Self.transform(a.string("transform"))))
            case "basematerials", "colorgroup":
                currentGroup = (a.int("id") ?? 0, [])
            case "base":
                currentGroup?.1.append(self.colorIndex(a.string("displaycolor")))
            case "color":
                currentGroup?.1.append(self.colorIndex(a.string("color")))
            default: break
            }
        }
        return file
    }

    static func transform(_ s: String?) -> simd_float4x4 {
        guard let s else { return matrix_identity_float4x4 }
        let v = s.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }).compactMap { Float($0) }
        guard v.count == 12 else { return matrix_identity_float4x4 }
        return simd_float4x4(columns: (
            SIMD4(v[0], v[1], v[2], 0),
            SIMD4(v[3], v[4], v[5], 0),
            SIMD4(v[6], v[7], v[8], 0),
            SIMD4(v[9], v[10], v[11], 1)))
    }

    // MARK: - Colors

    private func colorIndex(_ hex: String?) -> Int32 {
        guard let c = Self.parseColor(hex) else { return -1 }
        if let i = paletteIndex[c] { return i }
        let i = Int32(palette.count)
        palette.append(c)
        paletteIndex[c] = i
        return i
    }

    static func parseColor(_ hex: String?) -> SIMD4<Float>? {
        guard var h = hex?.trimmingCharacters(in: .whitespaces), h.hasPrefix("#") else { return nil }
        h.removeFirst()
        guard h.count == 6 || h.count == 8, let v = UInt32(h, radix: 16) else { return nil }
        let rgba = h.count == 6 ? (v << 8 | 0xFF) : v
        return SIMD4(Float((rgba >> 24) & 0xFF) / 255, Float((rgba >> 16) & 0xFF) / 255,
                     Float((rgba >> 8) & 0xFF) / 255, Float(rgba & 0xFF) / 255)
    }

    private func filamentColor(_ extruder: Int) -> Int32 {
        let i = extruder - 1
        return i >= 0 && i < filamentColors.count ? filamentColors[i] : -1
    }

    private func loadSlicerMetadata() {
        if let data = try? zip.read("Metadata/project_settings.config"),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let colors = (json["filament_colour"] ?? json["extruder_colour"]) as? [String] {
            filamentColors = colors.map { colorIndex($0) }
        }
        if let data = try? zip.read("Metadata/project_settings.config"),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            func str(_ k: String) -> String? {
                if let s = json[k] as? String, !s.isEmpty { return s }
                if let a = json[k] as? [String], let s = a.first, !s.isEmpty { return s }
                return nil
            }
            info.printer = str("printer_model") ?? str("printer_settings_id")
            if let n = str("nozzle_diameter") { info.nozzle = "\(n) mm" }
            if let l = str("layer_height") { info.layerHeight = "\(l) mm" }
            if let d = str("sparse_infill_density") { info.infill = d }
            if let types = json["filament_type"] as? [String] {
                var seen: [String] = []
                for t in types where !seen.contains(t) { seen.append(t) }
                info.filaments = seen
            }
            if let area = json["printable_area"] as? [String] {
                var mx: Float = 0, my: Float = 0
                for pt in area {
                    let c = pt.split(separator: "x").compactMap { Float($0) }
                    if c.count == 2 { mx = max(mx, c[0]); my = max(my, c[1]) }
                }
                if mx > 0, my > 0 { info.bedSize = [mx, my] }
            }
        }
        if let data = try? zip.read("Metadata/model_settings.config") {
            var objID: Int?
            var partID: Int?
            var plate: (id: Int, name: String, objects: Set<Int>)?
            XMLScanner.scan(data, onEnd: { tag in
                if tag == "part" { partID = nil }
                if tag == "object" { objID = nil }
                if tag == "plate", let p = plate {
                    self.plates.append(Plate(index: self.plates.count, name: p.name.isEmpty ? "Plate \(p.id)" : p.name, objectIDs: p.objects))
                    plate = nil
                }
            }) { tag, a in
                switch tag {
                case "plate": plate = (self.plates.count + 1, "", [])
                case "object": objID = a.int("id"); partID = nil
                case "part": partID = a.int("id")
                case "metadata" where plate != nil:
                    switch a.string("key") {
                    case "plater_id": if let v = a.int("value") { plate!.id = v }
                    case "plater_name": plate!.name = a.string("value") ?? ""
                    case "object_id": if let v = a.int("value") { plate!.objects.insert(v) }
                    default: break
                    }
                case "metadata":
                    guard a.string("key") == "extruder", let ex = a.int("value") else { return }
                    if let p = partID, let o = objID { self.partExtruder[o, default: [:]][p] = ex }
                    else if let o = objID { self.objectExtruder[o] = ex }
                default: break
                }
            }
        }
    }

    // MARK: - Thumbnail

    func embeddedThumbnail() -> Data? { findThumbnail() }

    /// Bambu/Orca sliced projects: Metadata/slice_info.config + Metadata/plate_N.png.
    private func loadSliceInfo(into model: inout ThreeMFModel) {
        guard let data = try? zip.read("Metadata/slice_info.config") else { return }
        var current: SlicedPlate?
        var index = 0
        var plates: [SlicedPlate] = []
        XMLScanner.scan(data, onEnd: { tag in
            if tag == "plate", var p = current {
                p.image = try? self.zip.read("Metadata/plate_\(index).png")
                plates.append(p)
                current = nil
            }
        }) { tag, a in
            switch tag {
            case "plate": current = SlicedPlate(name: ""); index = plates.count + 1
            case "metadata" where current != nil:
                switch a.string("key") {
                case "index": index = a.int("value") ?? index
                case "prediction": current?.seconds = a.int("value")
                case "weight": current?.grams = Double(a.string("value") ?? "")
                default: break
                }
            default: break
            }
        }
        guard !plates.isEmpty else { return }
        // Names from model_settings plates where available
        for i in plates.indices {
            plates[i].name = i < self.plates.count ? self.plates[i].name : "Plate \(i + 1)"
        }
        model.sliced = plates
        let secs = plates.compactMap(\.seconds).reduce(0, +)
        let grams = plates.compactMap(\.grams).reduce(0, +)
        if secs > 0 { info.printTime = Format.duration(secs) }
        if grams > 0 { info.filamentWeight = Format.grams(grams) }
    }

    /// <metadata name="Title">…</metadata> etc. live near the top of the root model.
    private func readModelMetadata(_ data: Data) {
        let head = String(decoding: data.prefix(256 * 1024), as: UTF8.self)
        func meta(_ name: String) -> String? {
            guard let r = head.range(of: "<metadata name=\"\(name)\">") else { return nil }
            guard let e = head.range(of: "</metadata>", range: r.upperBound..<head.endIndex) else { return nil }
            var v = String(head[r.upperBound..<e.lowerBound])
            for (a, b) in [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#34;", "\""), ("&apos;", "'"), ("&amp;", "&")] {
                v = v.replacingOccurrences(of: a, with: b)
            }
            v = v.trimmingCharacters(in: .whitespacesAndNewlines)
            return v.isEmpty ? nil : v
        }
        info.title = meta("Title")
        info.designer = meta("Designer")
    }

    private func findThumbnail() -> Data? {
        let candidates = ["Metadata/plate_1.png", "Metadata/thumbnail.png", "Auxiliaries/.thumbnails/thumbnail_middle.png",
                          "Auxiliaries/.thumbnails/thumbnail_3mf.png", "Metadata/thumbnail.jpg"]
        for c in candidates { if let d = try? zip.read(c) { return d } }
        return nil
    }
}

// MARK: - Tiny fast XML tag scanner

struct XMLAttributes {
    fileprivate let base: UnsafePointer<UInt8>
    fileprivate var items: [(name: Range<Int>, value: Range<Int>)] = []

    private func find(_ key: String) -> Range<Int>? {
        let k = Array(key.utf8)
        outer: for it in items {
            // compare local name (after optional prefix:)
            var start = it.name.lowerBound
            for i in it.name where base[i] == UInt8(ascii: ":") { start = i + 1 }
            guard it.name.upperBound - start == k.count else { continue }
            for j in 0..<k.count where base[start + j] != k[j] { continue outer }
            return it.value
        }
        return nil
    }

    func string(_ key: String) -> String? {
        guard let r = find(key) else { return nil }
        let s = String(decoding: UnsafeBufferPointer(start: base + r.lowerBound, count: r.count), as: UTF8.self)
        return s.contains("&") ? s.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&apos;", with: "'") : s
    }

    func float(_ key: String) -> Float {
        guard let r = find(key) else { return 0 }
        return (base + r.lowerBound).withMemoryRebound(to: CChar.self, capacity: r.count) { strtof($0, nil) }
    }

    func int(_ key: String) -> Int? {
        guard let r = find(key), !r.isEmpty else { return nil }
        var v = 0, neg = false, i = r.lowerBound
        if base[i] == UInt8(ascii: "-") { neg = true; i += 1 }
        var any = false
        while i < r.upperBound, base[i] >= 48, base[i] <= 57 { v = v * 10 + Int(base[i] - 48); i += 1; any = true }
        return any ? (neg ? -v : v) : nil
    }
}

enum XMLScanner {
    /// Calls `onStart(localTagName, attributes)` for every start/empty tag, `onEnd` for close tags
    /// (and right after self-closing tags). Not a validating parser — just fast.
    static func scan(_ data: Data, onEnd: ((String) -> Void)? = nil,
                     onStart: (String, XMLAttributes) -> Void) {
        // Ensure a trailing NUL so strtof never runs off the end.
        var d = data
        d.append(0)
        d.withUnsafeBytes { raw in
            let p = raw.bindMemory(to: UInt8.self).baseAddress!
            let n = raw.count - 1
            var attrs = XMLAttributes(base: p)
            attrs.items.reserveCapacity(16)
            var nameCache: [Int: String] = [:]
            func name(_ s: Int, _ e: Int) -> String {
                var start = s
                for i in s..<e where p[i] == UInt8(ascii: ":") { start = i + 1 }
                // cheap hash on local name for caching
                var h = e - start
                for i in start..<e { h = h &* 31 &+ Int(p[i]) }
                if let c = nameCache[h] { return c }
                let str = String(decoding: UnsafeBufferPointer(start: p + start, count: e - start), as: UTF8.self)
                nameCache[h] = str
                return str
            }
            @inline(__always) func isSpace(_ c: UInt8) -> Bool { c == 32 || c == 9 || c == 10 || c == 13 }
            @inline(__always) func isNameEnd(_ c: UInt8) -> Bool {
                isSpace(c) || c == UInt8(ascii: ">") || c == UInt8(ascii: "/") || c == UInt8(ascii: "=")
            }

            var i = 0
            while i < n {
                guard let lt = memchr(p + i, 0x3C, n - i) else { break }
                i = p.distance(to: lt.assumingMemoryBound(to: UInt8.self)) + 1
                guard i < n else { break }
                let c = p[i]
                if c == UInt8(ascii: "?") || c == UInt8(ascii: "!") {
                    // comment / CDATA / PI / doctype
                    if i + 2 < n, p[i + 1] == UInt8(ascii: "-"), p[i + 2] == UInt8(ascii: "-") {
                        while i + 2 < n, !(p[i] == 45 && p[i + 1] == 45 && p[i + 2] == 62) { i += 1 }
                        i += 3
                    } else {
                        while i < n, p[i] != UInt8(ascii: ">") { i += 1 }
                    }
                    continue
                }
                if c == UInt8(ascii: "/") {
                    let s = i + 1
                    var e = s
                    while e < n, !isNameEnd(p[e]) { e += 1 }
                    onEnd?(name(s, e))
                    i = e
                    continue
                }
                let s = i
                var e = s
                while e < n, !isNameEnd(p[e]) { e += 1 }
                let tag = name(s, e)
                attrs.items.removeAll(keepingCapacity: true)
                i = e
                var selfClosing = false
                while i < n {
                    while i < n, isSpace(p[i]) { i += 1 }
                    guard i < n else { break }
                    if p[i] == UInt8(ascii: ">") { i += 1; break }
                    if p[i] == UInt8(ascii: "/") { selfClosing = true; i += 1; continue }
                    let ns = i
                    while i < n, !isNameEnd(p[i]) { i += 1 }
                    let ne = i
                    while i < n, p[i] != UInt8(ascii: "\""), p[i] != UInt8(ascii: "'"), p[i] != UInt8(ascii: ">") { i += 1 }
                    guard i < n, p[i] != UInt8(ascii: ">") else { continue }
                    let q = p[i]; i += 1
                    let vs = i
                    while i < n, p[i] != q { i += 1 }
                    attrs.items.append((ns..<ne, vs..<i))
                    i += 1
                }
                onStart(tag, attrs)
                if selfClosing { onEnd?(tag) }
            }
        }
    }
}
