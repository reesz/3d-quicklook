// Renders README screenshots offscreen from Samples/sample-plates.3mf.
// Build & run: Tools/screenshots.sh
import AppKit
import SceneKit

let root = URL(fileURLWithPath: CommandLine.arguments[1])
let sample = root.appendingPathComponent("Samples/sample-plates.3mf")
let out = root.appendingPathComponent("docs")
InfoLine.logoDirectory = root.appendingPathComponent("Preview/Logos")
let model = try ThreeMFLoader.load(url: sample)
let result = SceneBuilder.build(model)
let renderer = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil)
renderer.scene = result.scene
renderer.pointOfView = result.camera
let W: CGFloat = 1000, H: CGFloat = 680

func save(_ img: NSImage, _ name: String) {
    let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
    try! rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent(name))
    print("wrote docs/\(name)")
}

func panel(_ rect: NSRect, dark: Bool) {
    NSColor(white: dark ? 0.2 : 1, alpha: dark ? 0.85 : 0.85).setFill()
    NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10).fill()
}

func infoLines(plate: Plate?) -> [NSAttributedString] {
    let st = result.stats
    let i = model.info
    let title = NSAttributedString(string: "\(i.title ?? "") by \(i.designer ?? "")",
        attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.labelColor])
    var a: [InfoLine.Item] = []
    if let plate { a.append(.init(icon: .symbol("square.on.square"), text: plate.name, help: "")) }
    a += [.init(icon: .symbol("triangle"), text: String(format: "%.1fK", Double(st.triangles) / 1000), help: ""),
          .init(icon: .symbol("cube"), text: "\(st.objects)", help: ""),
          .init(icon: .symbol("ruler"), text: String(format: "%.1f × %.1f × %.1f mm", st.size.x, st.size.y, st.size.z), help: "")]
    let b: [InfoLine.Item] = [
        .init(icon: InfoLine.printerIcon(i.printer ?? ""), text: i.printer ?? "", help: ""),
        .init(icon: .custom(InfoLine.nozzle), text: i.nozzle ?? "", help: ""),
        .init(icon: .symbol("square.3.layers.3d"), text: i.layerHeight ?? "", help: ""),
        .init(icon: .custom(InfoLine.spool), text: i.filaments.joined(separator: ", "), help: ""),
        .init(icon: .symbol("square.grid.3x3"), text: i.infill ?? "", help: "")]
    return [title, InfoLine.make(a, monospacedDigits: true), InfoLine.make(b, monospacedDigits: false)]
}

func shot(plate: Plate?, dark: Bool, name: String) {
    result.showPlate = true
    result.dark = dark
    result.show(objects: plate?.objectIDs, plate: plate?.index)
    let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
    let scene = renderer.snapshot(atTime: 0, with: CGSize(width: W * 2, height: H * 2), antialiasingMode: .multisampling4X)
    let img = NSImage(size: NSSize(width: W, height: H))
    appearance.performAsCurrentDrawingAppearance {
        img.lockFocus()
        NSColor(white: dark ? 0.11 : 0.96, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: W, height: H).fill()
        scene.draw(in: NSRect(x: 0, y: 0, width: W, height: H))
        // plate picker mock
        let pickerText = NSAttributedString(string: "‹  ›    \(plate.map { "\($0.index + 1). \($0.name)" } ?? "All plates")  ⌄",
            attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor])
        let pr = NSRect(x: 14, y: H - 44, width: pickerText.size().width + 24, height: 30)
        panel(pr, dark: dark)
        pickerText.draw(at: NSPoint(x: pr.minX + 12, y: pr.minY + 7))
        // info panel
        let lines = infoLines(plate: plate)
        let w = lines.map { $0.size().width }.max()! + 26
        let r = NSRect(x: 14, y: 14, width: w, height: 70)
        panel(r, dark: dark)
        var y = r.maxY - 25
        for l in lines { l.draw(at: NSPoint(x: r.minX + 13, y: y)); y -= 20 }
        img.unlockFocus()
    }
    save(img, name)
}

shot(plate: model.plates[0], dark: true, name: "preview-dark.png")
shot(plate: model.plates[1], dark: false, name: "preview-light.png")
shot(plate: nil, dark: true, name: "all-plates.png")

// Grid of plates
result.dark = true
let grid = PlateGridView(frame: NSRect(x: 0, y: 0, width: W, height: H))
grid.appearance = NSAppearance(named: .darkAqua)
grid.contentInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
grid.setPlates(model.plates.enumerated().map { "\($0.offset + 1). \($0.element.name)" })
grid.layoutSubtreeIfNeeded()
let ts = grid.tileSize
for (i, p) in model.plates.enumerated() {
    result.show(objects: p.objectIDs, plate: p.index)
    grid.tiles[i].setImage(renderer.snapshot(atTime: 0, with: CGSize(width: ts.width * 2, height: ts.height * 2), antialiasingMode: .multisampling4X))
}
let bg = NSView(frame: grid.frame)
bg.wantsLayer = true
bg.layer?.backgroundColor = NSColor(white: 0.11, alpha: 1).cgColor
bg.appearance = NSAppearance(named: .darkAqua)
bg.addSubview(grid)
let rep = bg.bitmapImageRepForCachingDisplay(in: bg.bounds)!
bg.cacheDisplay(in: bg.bounds, to: rep)
let gimg = NSImage(size: bg.bounds.size); gimg.addRepresentation(rep)
save(gimg, "grid.png")

// Finder thumbnail (no plate grid, transparent)
result.showPlate = false
result.show(objects: nil)
let thumb = SceneBuilder.snapshot(result, size: CGSize(width: 512, height: 512))!
save(thumb, "thumbnail.png")
