import Foundation
import simd

/// Entry point for every supported file type.
enum ModelLoader {
    enum LoadError: Error { case unsupported, empty }

    static func kind(_ url: URL) -> String {
        let name = url.lastPathComponent.lowercased()
        if name.hasSuffix(".gcode.3mf") { return "3mf" }
        return url.pathExtension.lowercased()
    }

    static func load(url: URL) throws -> ThreeMFModel {
        switch kind(url) {
        case "stl": return try single(STLLoader.load(url), url)
        case "obj": return try single(OBJLoader.load(url), url)
        case "ply": return try single(PLYLoader.load(url), url)
        case "amf": return try AMFLoader.load(url)
        case "bgcode": return try BGCodeLoader.load(url)
        case "gcode", "gco", "g": return try GCodeLoader.load(url)
        default: return try ThreeMFLoader.load(url: url)
        }
    }

    /// Cheap path for thumbnails: an image the slicer embedded, if any.
    static func embeddedThumbnail(url: URL) -> Data? {
        switch kind(url) {
        case "stl", "obj", "ply", "amf": return nil
        case "bgcode": return BGCodeLoader.thumbnails(url).last
        case "gcode", "gco", "g": return GCodeLoader.thumbnails(url).last
        default: return (try? ThreeMFLoader(url: url))?.embeddedThumbnail()
        }
    }

    private static func single(_ mesh: MeshData, _ url: URL) throws -> ThreeMFModel {
        guard !mesh.triangles.isEmpty else { throw LoadError.empty }
        var m = ThreeMFModel()
        m.instances = [MeshInstance(mesh: mesh, transform: matrix_identity_float4x4, defaultColor: -1, rootObject: 1)]
        m.info.title = url.deletingPathExtension().lastPathComponent
        return m
    }
}

// MARK: - STL

enum STLLoader {
    static func load(_ url: URL) throws -> MeshData {
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        let mesh = MeshData()
        if data.count >= 84 {
            let n = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 80, as: UInt32.self) }
            if 84 + Int(n) * 50 == data.count {            // binary STL
                mesh.positions.reserveCapacity(Int(n) * 3)
                mesh.triangles.reserveCapacity(Int(n) * 3)
                data.withUnsafeBytes { raw in
                    for t in 0..<Int(n) {
                        let o = 84 + t * 50 + 12             // skip normal
                        for k in 0..<3 {
                            let p = o + k * 12
                            mesh.positions.append(SIMD3(raw.loadUnaligned(fromByteOffset: p, as: Float.self),
                                                        raw.loadUnaligned(fromByteOffset: p + 4, as: Float.self),
                                                        raw.loadUnaligned(fromByteOffset: p + 8, as: Float.self)))
                            mesh.triangles.append(UInt32(t * 3 + k))
                        }
                    }
                }
                mesh.triColors = []
                return mesh
            }
        }
        // ASCII STL: "vertex x y z" lines, three per facet
        var d = data
        d.append(0)
        d.withUnsafeBytes { raw in
            let p = raw.bindMemory(to: CChar.self).baseAddress!
            var i = 0
            let n = raw.count - 1
            while i < n {
                // find "vertex"
                guard let hit = strstr(p + i, "vertex") else { break }
                var end: UnsafeMutablePointer<CChar>?
                var q = UnsafeMutablePointer(mutating: hit + 6)
                let x = strtof(q, &end); q = end!
                let y = strtof(q, &end); q = end!
                let z = strtof(q, &end); q = end!
                mesh.positions.append(SIMD3(x, y, z))
                i = p.distance(to: q)
            }
        }
        let count = mesh.positions.count / 3 * 3
        mesh.positions.removeLast(mesh.positions.count - count)
        mesh.triangles = (0..<UInt32(count)).map { $0 }
        return mesh
    }
}

// MARK: - OBJ

enum OBJLoader {
    static func load(_ url: URL) throws -> MeshData {
        let text = try String(contentsOf: url, encoding: .utf8)
        let mesh = MeshData()
        var face: [Int] = []
        for lineSub in text.split(whereSeparator: \.isNewline) {
            let line = lineSub.drop(while: { $0 == " " || $0 == "\t" })
            if line.hasPrefix("v ") {
                let c = line.dropFirst(2).split(separator: " ", omittingEmptySubsequences: true).prefix(3).compactMap { Float($0) }
                if c.count == 3 { mesh.positions.append(SIMD3(c[0], c[1], c[2])) }
            } else if line.hasPrefix("f ") {
                face.removeAll(keepingCapacity: true)
                for tok in line.dropFirst(2).split(separator: " ", omittingEmptySubsequences: true) {
                    guard let v = Int(tok.split(separator: "/", omittingEmptySubsequences: false).first ?? "") else { continue }
                    let idx = v < 0 ? mesh.positions.count + v : v - 1      // 1-based, negatives are relative
                    if idx >= 0 { face.append(idx) }
                }
                guard face.count >= 3 else { continue }
                for k in 1..<(face.count - 1) {                                // fan triangulation
                    mesh.triangles += [UInt32(face[0]), UInt32(face[k]), UInt32(face[k + 1])]
                }
            }
        }
        // OBJ is usually Y-up; 3MF/our scene expects Z-up.
        mesh.positions = mesh.positions.map { SIMD3($0.x, -$0.z, $0.y) }
        return mesh
    }
}
