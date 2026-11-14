import Foundation
import simd

// MARK: - PLY (ascii, binary little/big endian)

enum PLYLoader {
    enum PLYError: Error { case badHeader }

    private enum T: String { case char, uchar, short, ushort, int, uint, float, double,
                                  int8, uint8, int16, uint16, int32, uint32, float32, float64
        var size: Int {
            switch self {
            case .char, .uchar, .int8, .uint8: return 1
            case .short, .ushort, .int16, .uint16: return 2
            case .int, .uint, .float, .int32, .uint32, .float32: return 4
            case .double, .float64: return 8
            }
        }
    }
    private struct Prop { let name: String; let type: T; let listCount: T? }
    private struct Element { let name: String; let count: Int; var props: [Prop] }

    static func load(_ url: URL) throws -> MeshData {
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        guard let headerEnd = data.range(of: Data("end_header".utf8)) else { throw PLYError.badHeader }
        var bodyStart = headerEnd.upperBound
        while bodyStart < data.count, data[bodyStart] == 0x0D || data[bodyStart] == 0x0A {
            bodyStart += 1
            if data[bodyStart - 1] == 0x0A { break }
        }
        let header = String(decoding: data[..<headerEnd.lowerBound], as: UTF8.self)
        var format = "ascii"
        var elements: [Element] = []
        for line in header.split(whereSeparator: \.isNewline) {
            let w = line.split(separator: " ").map(String.init)
            guard let k = w.first else { continue }
            if k == "format", w.count > 1 { format = w[1] }
            if k == "element", w.count == 3 { elements.append(Element(name: w[1], count: Int(w[2]) ?? 0, props: [])) }
            if k == "property", !elements.isEmpty {
                if w.count == 5, w[1] == "list", let c = T(rawValue: w[2]), let t = T(rawValue: w[3]) {
                    elements[elements.count - 1].props.append(Prop(name: w[4], type: t, listCount: c))
                } else if w.count == 3, let t = T(rawValue: w[1]) {
                    elements[elements.count - 1].props.append(Prop(name: w[2], type: t, listCount: nil))
                }
            }
        }
        let mesh = MeshData()
        if format == "ascii" {
            let body = String(decoding: data[bodyStart...], as: UTF8.self)
            var lines = body.split(whereSeparator: \.isNewline).makeIterator()
            for el in elements {
                for _ in 0..<el.count {
                    guard let line = lines.next() else { break }
                    let nums = line.split(separator: " ").compactMap { Double($0) }
                    var i = 0
                    var vals: [String: Double] = [:]
                    var list: [Int] = []
                    for p in el.props {
                        if p.listCount != nil {
                            let n = i < nums.count ? Int(nums[i]) : 0; i += 1
                            list = (0..<n).compactMap { i + $0 < nums.count ? Int(nums[i + $0]) : nil }; i += n
                        } else { vals[p.name] = i < nums.count ? nums[i] : 0; i += 1 }
                    }
                    add(el.name, vals, list, mesh)
                }
            }
        } else {
            let big = format == "binary_big_endian"
            data.withUnsafeBytes { raw in
                var o = bodyStart
                func read(_ t: T) -> Double {
                    guard o + t.size <= raw.count else { o = raw.count; return 0 }
                    defer { o += t.size }
                    func u<I: FixedWidthInteger>(_: I.Type) -> I {
                        let v = raw.loadUnaligned(fromByteOffset: o, as: I.self); return big ? I(bigEndian: v) : I(littleEndian: v)
                    }
                    switch t {
                    case .char, .int8: return Double(raw.loadUnaligned(fromByteOffset: o, as: Int8.self))
                    case .uchar, .uint8: return Double(raw[o])
                    case .short, .int16: return Double(u(Int16.self))
                    case .ushort, .uint16: return Double(u(UInt16.self))
                    case .int, .int32: return Double(u(Int32.self))
                    case .uint, .uint32: return Double(u(UInt32.self))
                    case .float, .float32: return Double(Float(bitPattern: u(UInt32.self)))
                    case .double, .float64: return Double(bitPattern: u(UInt64.self))
                    }
                }
                for el in elements {
                    for _ in 0..<el.count {
                        var vals: [String: Double] = [:]
                        var list: [Int] = []
                        for p in el.props {
                            if let c = p.listCount {
                                let n = Int(read(c))
                                list = (0..<max(0, n)).map { _ in Int(read(p.type)) }
                            } else { vals[p.name] = read(p.type) }
                        }
                        add(el.name, vals, list, mesh)
                    }
                }
            }
        }
        return mesh
    }

    private static func add(_ el: String, _ v: [String: Double], _ list: [Int], _ mesh: MeshData) {
        if el == "vertex" {
            mesh.positions.append(SIMD3(Float(v["x"] ?? 0), Float(v["y"] ?? 0), Float(v["z"] ?? 0)))
        } else if el == "face", list.count >= 3 {
            for k in 1..<(list.count - 1) where list[0] >= 0 && list[k] >= 0 && list[k + 1] >= 0 {
                mesh.triangles += [UInt32(list[0]), UInt32(list[k]), UInt32(list[k + 1])]
            }
        }
    }
}

// MARK: - AMF (plain or zipped XML)

final class AMFLoader: NSObject, XMLParserDelegate {
    private var model = ThreeMFModel()
    private var palette: [SIMD4<Float>] = []
    private var materials: [String: Int32] = [:]
    private var mesh: MeshData?
    private var volumeColor: Int32 = -1
    private var objectColor: Int32 = -1
    private var text = ""
    private var vtx = SIMD3<Float>(0, 0, 0)
    private var tri: [UInt32] = []
    private var rgb = SIMD4<Float>(0, 0, 0, 1)
    private var materialID: String?
    private var inColor = false
    private var objectID = 0

    static func load(_ url: URL) throws -> ThreeMFModel {
        var data = try Data(contentsOf: url)
        if data.starts(with: [0x50, 0x4B]) {        // zipped AMF: first entry is the XML
            let zip = try ZipReader(url: url)
            if let e = zip.entries.values.first { data = try zip.read(e) }
        }
        let l = AMFLoader()
        let p = XMLParser(data: data)
        p.delegate = l
        p.parse()
        l.model.palette = l.palette
        l.model.info.title = url.deletingPathExtension().lastPathComponent
        guard !l.model.instances.isEmpty else { throw ModelLoader.LoadError.empty }
        return l.model
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                attributes a: [String: String] = [:]) {
        text = ""
        switch name {
        case "object":
            objectID += 1
            mesh = MeshData(); objectColor = -1
        case "material": materialID = a["id"]
        case "color": inColor = true; rgb = [0, 0, 0, 1]
        case "volume":
            volumeColor = a["materialid"].flatMap { materials[$0] } ?? objectColor
        case "triangle": tri = []
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let v = Float(text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        switch name {
        case "x": vtx.x = v
        case "y": vtx.y = v
        case "z": vtx.z = v
        case "r": rgb.x = v
        case "g": rgb.y = v
        case "b": rgb.z = v
        case "vertex": mesh?.positions.append(vtx)
        case "v1", "v2", "v3": tri.append(UInt32(max(0, Int(v))))
        case "triangle":
            if tri.count == 3, let m = mesh { m.triangles += tri; m.triColors.append(volumeColor) }
        case "color":
            inColor = false
            palette.append(rgb)
            let idx = Int32(palette.count - 1)
            if let id = materialID { materials[id] = idx } else if mesh != nil { objectColor = idx; volumeColor = idx }
        case "material": materialID = nil
        case "object":
            if let m = mesh, !m.triangles.isEmpty {
                // pad triColors if some triangles were added before colors were known
                if m.triColors.count < m.triangles.count / 3 {
                    m.triColors += Array(repeating: -1, count: m.triangles.count / 3 - m.triColors.count)
                }
                model.instances.append(MeshInstance(mesh: m, transform: matrix_identity_float4x4,
                                                    defaultColor: objectColor, rootObject: objectID))
            }
            mesh = nil
        default: break
        }
    }
}
