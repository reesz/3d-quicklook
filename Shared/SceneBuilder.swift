import Foundation
import SceneKit
import simd
import AppKit

enum SceneBuilder {
    static let fallbackColor = SIMD4<Float>(0.85, 0.55, 0.20, 1)   // PLA orange

    /// Fragment-level flat normals, so we don't need to duplicate vertices per face.
    private static let flatShading = """
    #pragma body
    float3 dx = dfdx(_surface.position);
    float3 dy = dfdy(_surface.position);
    _surface.normal = normalize(cross(dx, dy));
    """

    struct Stats {
        var triangles = 0
        var objects = 0
        var size = SIMD3<Float>(0, 0, 0)   // mm, Z-up
    }

    final class Result {
        let scene = SCNScene()
        let camera = SCNNode()
        let world = SCNNode()                 // Z-up 3MF space
        let floor = SCNNode()
        fileprivate var parts: [(node: SCNNode, root: Int, tris: Int, lo: SIMD3<Float>, hi: SIMD3<Float>)] = []
        fileprivate var bedSize: SIMD2<Float>?
        fileprivate var plateCount = 0
        private(set) var center = SIMD3<Float>(0, 0, 0)
        private(set) var stats = Stats()

        var showPlate = false { didSet { rebuildFloor() } }
        var dark = false { didSet { rebuildFloor() } }

        private var currentPlate: Int?
        private var visLo = SIMD3<Float>(-10, -10, 0), visHi = SIMD3<Float>(10, 10, 10)

        /// Show only the given build objects (nil = everything) and fit the camera to them.
        /// `plate` is the slicer plate index, used to place the build-plate grid.
        func show(objects: Set<Int>?, plate: Int? = nil) {
            var lo = SIMD3<Float>(repeating: .infinity), hi = SIMD3<Float>(repeating: -.infinity)
            var st = Stats()
            var roots = Set<Int>()
            for p in parts {
                let visible = objects?.contains(p.root) ?? true
                p.node.isHidden = !visible
                if visible {
                    lo = simd_min(lo, p.lo); hi = simd_max(hi, p.hi)
                    st.triangles += p.tris
                    roots.insert(p.root)
                }
            }
            if !lo.x.isFinite { lo = [-10, -10, 0]; hi = [10, 10, 10] }
            st.objects = roots.count
            st.size = hi - lo
            stats = st
            visLo = lo; visHi = hi
            currentPlate = plate
            rebuildFloor()
            frame(lo: lo, hi: hi)
        }

        // MARK: Build plate

        /// Bambu/Orca lay plates out in a grid: cols = round-up sqrt(n), 20% gap.
        private func bedRect(_ i: Int) -> (SIMD2<Float>, SIMD2<Float>)? {
            guard let bed = bedSize, plateCount > 0 else { return nil }
            let v = Float(plateCount).squareRoot()
            let cols = max(1, Int(v > v.rounded() ? v.rounded() + 1 : v.rounded()))
            let col = i % cols, row = i / cols
            let o = SIMD2<Float>(Float(col) * bed.x * 1.2, -Float(row) * bed.y * 1.2)
            return (o, o + bed)
        }

        private func rebuildFloor() {
            floor.childNodes.forEach { $0.removeFromParentNode() }
            guard showPlate else { return }

            var rects: [(SIMD2<Float>, SIMD2<Float>)] = []
            if let p = currentPlate, let r = bedRect(p) {
                rects = [r]
            } else if currentPlate == nil, bedSize != nil, plateCount > 0 {
                rects = (0..<plateCount).compactMap(bedRect)
            }
            // Sanity: objects must sit on the computed beds, otherwise fall back to a fitted grid.
            let c = SIMD2((visLo.x + visHi.x) / 2, (visLo.y + visHi.y) / 2)
            if currentPlate != nil || rects.isEmpty, !rects.contains(where: { c.x >= $0.0.x && c.y >= $0.0.y && c.x <= $0.1.x && c.y <= $0.1.y }) {
                if let bed = bedSize {
                    let o = c - bed / 2
                    rects = [(o, o + bed)]
                } else {
                    let ext = max(visHi.x - visLo.x, visHi.y - visLo.y) * 1.6 + 20
                    let half = SIMD2<Float>(repeating: (ext / 20).rounded(.up) * 10)
                    rects = [(c - half, c + half)]
                }
            }
            for r in rects { floor.addChildNode(gridNode(r.0, r.1)) }
        }

        private func gridNode(_ lo: SIMD2<Float>, _ hi: SIMD2<Float>) -> SCNNode {
            let z = visLo.z - 0.02
            var minor: [SIMD3<Float>] = [], major: [SIMD3<Float>] = []
            func lines(_ step: Float, into arr: inout [SIMD3<Float>]) {
                var x = lo.x
                while x <= hi.x + 0.01 { arr += [[x, lo.y, z], [x, hi.y, z]]; x += step }
                var y = lo.y
                while y <= hi.y + 0.01 { arr += [[lo.x, y, z], [hi.x, y, z]]; y += step }
            }
            lines(10, into: &minor)
            lines(50, into: &major)
            major += [[lo.x, lo.y, z], [hi.x, lo.y, z], [hi.x, lo.y, z], [hi.x, hi.y, z],
                      [hi.x, hi.y, z], [lo.x, hi.y, z], [lo.x, hi.y, z], [lo.x, lo.y, z]]

            func lineGeo(_ pts: [SIMD3<Float>], _ color: NSColor) -> SCNNode {
                let src = SCNGeometrySource(vertices: pts.map { SCNVector3($0.x, $0.y, $0.z) })
                let idx = (0..<UInt32(pts.count)).map { $0 }
                let el = SCNGeometryElement(indices: idx, primitiveType: .line)
                let g = SCNGeometry(sources: [src], elements: [el])
                let m = SCNMaterial(); m.lightingModel = .constant; m.diffuse.contents = color
                g.materials = [m]
                return SCNNode(geometry: g)
            }
            let n = SCNNode()
            let base: CGFloat = dark ? 1 : 0
            let plane = SCNPlane(width: CGFloat(hi.x - lo.x), height: CGFloat(hi.y - lo.y))
            let pm = SCNMaterial(); pm.lightingModel = .constant
            pm.diffuse.contents = NSColor(white: dark ? 0.16 : 0.9, alpha: 1)
            pm.isDoubleSided = true
            plane.materials = [pm]
            let pn = SCNNode(geometry: plane)
            pn.simdPosition = [(lo.x + hi.x) / 2, (lo.y + hi.y) / 2, z - 0.05]
            n.addChildNode(pn)
            n.addChildNode(lineGeo(minor, NSColor(white: base, alpha: 0.10)))
            n.addChildNode(lineGeo(major, NSColor(white: base, alpha: 0.28)))
            return n
        }

        private func frame(lo: SIMD3<Float>, hi: SIMD3<Float>) {
            // Bounds are Z-up; scene is Y-up.
            let c = (lo + hi) / 2
            center = SIMD3<Float>(c.x, c.z, -c.y)
            let radius = max(simd_length(hi - lo) / 2, 1)

            let cam = camera.camera!
            cam.zNear = Double(radius) * 0.01
            cam.zFar = Double(radius) * 200
            let dir = simd_normalize(SIMD3<Float>(0.6, 0.75, 1.0))
            let right = simd_normalize(simd_cross([0, 1, 0], dir))
            let up = simd_cross(dir, right)
            let tanHalf = tan(Float(cam.fieldOfView / 2) * .pi / 180)
            var distance: Float = 0
            for i in 0..<8 {
                let cz = SIMD3<Float>(i & 1 == 0 ? lo.x : hi.x, i & 2 == 0 ? lo.y : hi.y, i & 4 == 0 ? lo.z : hi.z)
                let v = SIMD3<Float>(cz.x, cz.z, -cz.y) - center
                distance = max(distance, max(abs(simd_dot(v, up)), abs(simd_dot(v, right))) / tanHalf + simd_dot(v, dir))
            }
            camera.simdPosition = center + dir * distance * 1.08
            camera.simdLook(at: center, up: [0, 1, 0], localFront: [0, 0, -1])
        }
    }

    static func build(_ model: ThreeMFModel) -> Result {
        let result = Result()
        let scene = result.scene
        // 3MF is Z-up; SceneKit is Y-up.
        let world = result.world
        world.simdTransform = simd_float4x4(simd_quatf(angle: -.pi / 2, axis: [1, 0, 0]))
        scene.rootNode.addChildNode(world)

        var materials: [Int32: SCNMaterial] = [:]
        func material(_ idx: Int32) -> SCNMaterial {
            if let m = materials[idx] { return m }
            let c = idx >= 0 && Int(idx) < model.palette.count ? model.palette[Int(idx)] : fallbackColor
            let m = SCNMaterial()
            m.lightingModel = .blinn
            m.diffuse.contents = NSColor(srgbRed: CGFloat(c.x), green: CGFloat(c.y), blue: CGFloat(c.z), alpha: 1)
            m.specular.contents = NSColor(white: 0.25, alpha: 1)
            m.shininess = 0.3
            m.isDoubleSided = true
            m.shaderModifiers = [.surface: flatShading]
            materials[idx] = m
            return m
        }

        var geometries: [String: SCNGeometry] = [:]
        var bounds: [ObjectIdentifier: (SIMD3<Float>, SIMD3<Float>)] = [:]

        for inst in model.instances {
            let mesh = inst.mesh
            let key = "\(ObjectIdentifier(mesh).hashValue)-\(inst.defaultColor)"
            let geo: SCNGeometry
            if let g = geometries[key] {
                geo = g
            } else {
                geo = makeGeometry(mesh, defaultColor: inst.defaultColor, material: material)
                geometries[key] = geo
            }
            let node = SCNNode(geometry: geo)
            node.simdTransform = inst.transform
            world.addChildNode(node)

            let b: (SIMD3<Float>, SIMD3<Float>)
            if let cached = bounds[ObjectIdentifier(mesh)] { b = cached } else {
                var l = SIMD3<Float>(repeating: .infinity), h = SIMD3<Float>(repeating: -.infinity)
                for p in mesh.positions { l = simd_min(l, p); h = simd_max(h, p) }
                b = (l, h); bounds[ObjectIdentifier(mesh)] = b
            }
            var lo = SIMD3<Float>(repeating: .infinity), hi = SIMD3<Float>(repeating: -.infinity)
            for i in 0..<8 {
                let corner = SIMD3<Float>(i & 1 == 0 ? b.0.x : b.1.x, i & 2 == 0 ? b.0.y : b.1.y, i & 4 == 0 ? b.0.z : b.1.z)
                let w = inst.transform * SIMD4(corner, 1)
                lo = simd_min(lo, SIMD3(w.x, w.y, w.z)); hi = simd_max(hi, SIMD3(w.x, w.y, w.z))
            }
            if lo.x.isFinite { result.parts.append((node, inst.rootObject, mesh.triangles.count / 3, lo, hi)) }
        }

        world.addChildNode(result.floor)
        result.bedSize = model.info.bedSize
        result.plateCount = model.info.plateCount

        // Lights
        let ambient = SCNNode(); ambient.light = SCNLight(); ambient.light!.type = .ambient
        ambient.light!.intensity = 450
        scene.rootNode.addChildNode(ambient)
        for (dir, intensity) in [(SIMD3<Float>(-0.5, -1, -0.6), 750.0), (SIMD3<Float>(0.7, -0.3, 0.5), 300.0)] {
            let n = SCNNode(); n.light = SCNLight(); n.light!.type = .directional
            n.light!.intensity = CGFloat(intensity)
            n.simdLook(at: dir, up: [0, 1, 0], localFront: [0, 0, -1])
            scene.rootNode.addChildNode(n)
        }

        result.camera.camera = SCNCamera()
        result.camera.camera!.fieldOfView = 30
        scene.rootNode.addChildNode(result.camera)
        result.show(objects: nil)
        return result
    }

    private static func makeGeometry(_ mesh: MeshData, defaultColor: Int32,
                                     material: (Int32) -> SCNMaterial) -> SCNGeometry {
        let vdata = mesh.positions.withUnsafeBufferPointer { Data(buffer: $0) }
        let source = SCNGeometrySource(data: vdata, semantic: .vertex, vectorCount: mesh.positions.count,
                                       usesFloatComponents: true, componentsPerVector: 3,
                                       bytesPerComponent: 4, dataOffset: 0,
                                       dataStride: MemoryLayout<SIMD3<Float>>.stride)
        let vcount = UInt32(mesh.positions.count)
        let triCount = mesh.triangles.count / 3

        // Group triangles by resolved color
        var groups: [Int32: [UInt32]] = [:]
        let uniform = mesh.triColors.allSatisfy { $0 < 0 }
        if uniform {
            groups[defaultColor] = mesh.triangles
        } else {
            for t in 0..<triCount {
                var c = t < mesh.triColors.count ? mesh.triColors[t] : -1
                if c < 0 { c = defaultColor }
                groups[c, default: []].append(contentsOf: mesh.triangles[(t * 3)..<(t * 3 + 3)])
            }
        }

        var elements: [SCNGeometryElement] = []
        var mats: [SCNMaterial] = []
        for (color, var idx) in groups.sorted(by: { $0.key < $1.key }) {
            // Drop triangles with out-of-range indices instead of crashing the GPU.
            if idx.contains(where: { $0 >= vcount }) {
                var clean: [UInt32] = []
                clean.reserveCapacity(idx.count)
                for t in stride(from: 0, to: idx.count, by: 3)
                where idx[t] < vcount && idx[t + 1] < vcount && idx[t + 2] < vcount {
                    clean.append(contentsOf: idx[t..<(t + 3)])
                }
                idx = clean
            }
            let d = idx.withUnsafeBufferPointer { Data(buffer: $0) }
            elements.append(SCNGeometryElement(data: d, primitiveType: .triangles,
                                               primitiveCount: idx.count / 3, bytesPerIndex: 4))
            mats.append(material(color))
        }
        let g = SCNGeometry(sources: [source], elements: elements)
        g.materials = mats
        return g
    }

    /// Offscreen render to an image (used for thumbnails).
    static func snapshot(_ result: Result, size: CGSize) -> NSImage? {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        let r = SCNRenderer(device: device, options: nil)
        r.scene = result.scene
        r.pointOfView = result.camera
        r.scene?.background.contents = NSColor.clear
        return r.snapshot(atTime: 0, with: size, antialiasingMode: .multisampling4X)
    }
}
