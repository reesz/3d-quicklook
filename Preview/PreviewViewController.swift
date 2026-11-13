import Cocoa
import Quartz
import SceneKit

/// Keeps the last few parsed scenes around while the extension process lives,
/// so pressing Space on the same file again is instant.
private enum SceneCache {
    struct Entry { let key: String; let result: SceneBuilder.Result; let plates: [Plate]; let info: ModelInfo; let fileName: String }
    private static var entries: [Entry] = []
    private static let lock = NSLock()

    static func key(for url: URL) -> String {
        let v = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        return "\(url.path)|\(v?.contentModificationDate?.timeIntervalSince1970 ?? 0)|\(v?.fileSize ?? 0)"
    }
    static func get(_ key: String) -> Entry? {
        lock.lock(); defer { lock.unlock() }
        return entries.first { $0.key == key }
    }
    static func put(_ e: Entry) {
        lock.lock(); defer { lock.unlock() }
        entries.removeAll { $0.key == e.key }
        entries.insert(e, at: 0)
        if entries.count > 3 { entries.removeLast() }
    }
}

final class PreviewViewController: NSViewController, QLPreviewingController {
    private let scnView = SCNView()
    private let platePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let stepper = NSSegmentedControl(
        images: [NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Previous plate")!,
                 NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "Next plate")!],
        trackingMode: .momentary, target: nil, action: nil)
    private var result: SceneBuilder.Result?
    private var plates: [Plate] = []
    private var info = ModelInfo()
    private var fileName = ""
    private let infoPanel = NSVisualEffectView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let statsLabel = NSTextField(labelWithString: "")
    private let printLabel = NSTextField(labelWithString: "")
    private var appearanceObservation: NSKeyValueObservation?
    private let gridView = PlateGridView()
    private let layoutButton = NSButton()
    private let layoutButtonBG = NSVisualEffectView()
    /// Session override of the app setting, toggled with the top-right button.
    private var layoutOverride: PreviewSettings.AllPlatesLayout?
    private var allPlatesLayout: PreviewSettings.AllPlatesLayout { layoutOverride ?? PreviewSettings.allPlatesLayout }
    private var labelWidths: [NSLayoutConstraint] = []
    private lazy var renderer = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil)
    private var renderGeneration = 0
    private static var tileCache: [String: NSImage] = [:]

    override func loadView() {
        let root = NSView()
        scnView.allowsCameraControl = true
        scnView.antialiasingMode = .multisampling2X
        scnView.rendersContinuously = false
        scnView.isJitteringEnabled = false
        scnView.backgroundColor = .clear
        scnView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(scnView)

        gridView.translatesAutoresizingMaskIntoConstraints = false
        gridView.isHidden = true
        gridView.onSelect = { [weak self] i in self?.select(i + 1) }
        root.addSubview(gridView)

        // Plate picker: ‹ › stepper + dropdown (top-left)
        stepper.translatesAutoresizingMaskIntoConstraints = false
        stepper.target = self
        stepper.action = #selector(step)
        platePopup.translatesAutoresizingMaskIntoConstraints = false
        platePopup.target = self
        platePopup.action = #selector(popupChanged)
        let picker = NSStackView(views: [stepper, platePopup])
        picker.spacing = 6
        picker.translatesAutoresizingMaskIntoConstraints = false
        picker.isHidden = true
        picker.identifier = NSUserInterfaceItemIdentifier("picker")
        root.addSubview(picker)

        // All-plates layout toggle (top-right circle)
        layoutButtonBG.material = .hudWindow
        layoutButtonBG.blendingMode = .withinWindow
        layoutButtonBG.state = .active
        layoutButtonBG.wantsLayer = true
        layoutButtonBG.layer?.cornerRadius = 15
        layoutButtonBG.translatesAutoresizingMaskIntoConstraints = false
        layoutButtonBG.isHidden = true
        layoutButton.isBordered = false
        layoutButton.imagePosition = .imageOnly
        layoutButton.contentTintColor = .labelColor
        layoutButton.target = self
        layoutButton.action = #selector(toggleLayout)
        layoutButton.translatesAutoresizingMaskIntoConstraints = false
        layoutButtonBG.addSubview(layoutButton)
        root.addSubview(layoutButtonBG)

        // Model info panel (bottom-left)
        infoPanel.material = .hudWindow
        infoPanel.blendingMode = .withinWindow
        infoPanel.state = .active
        infoPanel.wantsLayer = true
        infoPanel.layer?.cornerRadius = 10
        infoPanel.translatesAutoresizingMaskIntoConstraints = false
        infoPanel.isHidden = true
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        for l in [titleLabel, statsLabel, printLabel] {
            l.lineBreakMode = .byTruncatingTail
            l.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        let infoStack = NSStackView(views: [titleLabel, statsLabel, printLabel])
        infoStack.orientation = .vertical
        infoStack.alignment = .leading
        infoStack.spacing = 4
        infoStack.edgeInsets = NSEdgeInsets(top: 9, left: 12, bottom: 9, right: 12)
        infoStack.translatesAutoresizingMaskIntoConstraints = false
        infoPanel.addSubview(infoStack)
        root.addSubview(infoPanel)

        NSLayoutConstraint.activate([
            scnView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scnView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scnView.topAnchor.constraint(equalTo: root.topAnchor),
            scnView.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            gridView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            gridView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            gridView.topAnchor.constraint(equalTo: root.topAnchor),
            gridView.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            picker.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            picker.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            picker.trailingAnchor.constraint(lessThanOrEqualTo: layoutButtonBG.leadingAnchor, constant: -12),

            layoutButtonBG.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            layoutButtonBG.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            layoutButtonBG.widthAnchor.constraint(equalToConstant: 30),
            layoutButtonBG.heightAnchor.constraint(equalToConstant: 30),
            layoutButton.centerXAnchor.constraint(equalTo: layoutButtonBG.centerXAnchor),
            layoutButton.centerYAnchor.constraint(equalTo: layoutButtonBG.centerYAnchor),
            layoutButton.widthAnchor.constraint(equalToConstant: 30),
            layoutButton.heightAnchor.constraint(equalToConstant: 30),

            infoPanel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            infoPanel.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
            infoPanel.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -12),
            infoStack.leadingAnchor.constraint(equalTo: infoPanel.leadingAnchor),
            infoStack.trailingAnchor.constraint(equalTo: infoPanel.trailingAnchor),
            infoStack.topAnchor.constraint(equalTo: infoPanel.topAnchor),
            infoStack.bottomAnchor.constraint(equalTo: infoPanel.bottomAnchor),
        ])

        view = root
        appearanceObservation = root.observe(\.effectiveAppearance) { [weak self] _, _ in
            DispatchQueue.main.async { self?.applyTheme() }
        }
        preferredContentSize = NSSize(width: 900, height: 700)
    }

    private var picker: NSView? { view.subviews.first { $0.identifier?.rawValue == "picker" } }

    func preparePreviewOfFile(at url: URL, completionHandler handler: @escaping (Error?) -> Void) {
        let key = SceneCache.key(for: url)
        if let cached = SceneCache.get(key) {
            info = cached.info; fileName = cached.fileName
            present(cached.result, plates: cached.plates)
            handler(nil)
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let model = try ThreeMFLoader.load(url: url)
                let result = SceneBuilder.build(model)
                SceneCache.put(.init(key: key, result: result, plates: model.plates,
                                     info: model.info, fileName: url.lastPathComponent))
                DispatchQueue.main.async {
                    self.info = model.info
                    self.fileName = url.lastPathComponent
                    self.present(result, plates: model.plates)
                    handler(nil)
                }
            } catch {
                DispatchQueue.main.async { handler(error) }
            }
        }
    }

    private func present(_ result: SceneBuilder.Result, plates: [Plate]) {
        self.result = result
        self.plates = plates
        result.showPlate = PreviewSettings.showPlate
        infoPanel.isHidden = !PreviewSettings.showInfo
        scnView.scene = result.scene
        applyTheme()

        platePopup.removeAllItems()
        if plates.count > 1 {
            platePopup.addItem(withTitle: "All plates")
            for (i, p) in plates.enumerated() { platePopup.addItem(withTitle: "\(i + 1). \(p.name)") }
            picker?.isHidden = false
        } else {
            picker?.isHidden = true
        }
        select(0)
    }

    @objc private func popupChanged() { select(platePopup.indexOfSelectedItem) }

    @objc private func step() {
        let n = platePopup.numberOfItems
        guard n > 1 else { return }
        select((platePopup.indexOfSelectedItem + (stepper.selectedSegment == 0 ? -1 : 1) + n) % n)
    }

    private func select(_ i: Int) {
        guard let result else { return }
        if platePopup.numberOfItems > i { platePopup.selectItem(at: i) }
        let plate = i <= 0 || i > plates.count ? nil : plates[i - 1]
        result.show(objects: plate?.objectIDs, plate: plate?.index)
        scnView.pointOfView = result.camera
        scnView.defaultCameraController.target = SCNVector3(result.center)
        updateInfo(plate: plate)

        let showGrid = plate == nil && plates.count > 1 && allPlatesLayout == .grid
        updateLayoutButton()
        gridView.isHidden = !showGrid
        scnView.isHidden = showGrid
        if showGrid { renderTiles() } else { renderGeneration += 1 }
    }

    @objc private func toggleLayout() {
        layoutOverride = allPlatesLayout == .grid ? .combined : .grid
        select(0)
    }

    private func updateLayoutButton() {
        layoutButtonBG.isHidden = plates.count <= 1
        let grid = allPlatesLayout == .grid
        // Shows what clicking switches to.
        let name = grid ? "square.on.square.dashed" : "square.grid.2x2"
        let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        layoutButton.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(cfg)
        layoutButton.toolTip = grid ? "Show plates in original layout" : "Show plates as a grid"
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        gridView.contentInsets = NSEdgeInsets(top: 52, left: 12,
                                              bottom: infoPanel.isHidden ? 12 : infoPanel.frame.height + 24, right: 12)
    }

    /// Renders one close-up per plate, one tile per runloop turn so the UI stays responsive.
    private func renderTiles() {
        guard let result else { return }
        renderGeneration += 1
        let gen = renderGeneration
        gridView.setPlates(plates.enumerated().map { "\($0.offset + 1). \($0.element.name)" })
        view.layoutSubtreeIfNeeded()
        let scale = view.window?.backingScaleFactor ?? 2
        let size = gridView.tileSize
        let px = CGSize(width: max(size.width, 200) * scale, height: max(size.height, 150) * scale)
        let dark = result.dark
        let base = "\(ObjectIdentifier(result).hashValue)-\(dark)-\(result.showPlate)-\(Int(px.width))"

        renderer.scene = result.scene
        renderer.pointOfView = result.camera
        for (i, plate) in plates.enumerated() {
            let key = "\(base)-\(i)"
            if let img = Self.tileCache[key] { gridView.tiles[i].setImage(img); continue }
            DispatchQueue.main.async { [weak self] in
                guard let self, gen == self.renderGeneration, i < self.gridView.tiles.count else { return }
                result.show(objects: plate.objectIDs, plate: plate.index)
                let img = self.renderer.snapshot(atTime: 0, with: px, antialiasingMode: .multisampling4X)
                result.show(objects: nil)          // keep "All plates" stats/camera as the live state
                Self.tileCache[key] = img
                if Self.tileCache.count > 64 { Self.tileCache.removeAll() }
                self.gridView.tiles[i].setImage(img)
            }
        }
    }

    override func keyDown(with event: NSEvent) {
        // ←/→ step through plates
        let n = platePopup.numberOfItems
        guard n > 1 else { return super.keyDown(with: event) }
        switch event.keyCode {
        case 123: select((platePopup.indexOfSelectedItem - 1 + n) % n)
        case 124: select((platePopup.indexOfSelectedItem + 1) % n)
        default: super.keyDown(with: event)
        }
    }

    private func applyTheme() {
        switch PreviewSettings.theme {
        case .system: view.appearance = nil
        case .light: view.appearance = NSAppearance(named: .aqua)
        case .dark: view.appearance = NSAppearance(named: .darkAqua)
        }
        let dark = view.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        scnView.backgroundColor = dark ? NSColor(white: 0.11, alpha: 1) : NSColor(white: 0.96, alpha: 1)
        if let result, result.dark != dark {
            result.dark = dark
            if !gridView.isHidden { renderTiles() }
        }
        if result != nil { updateInfo(plate: currentPlate) }
    }

    /// NSTextField under-measures attributed strings with attachments; size labels explicitly
    /// so the panel keeps its right padding.
    private func fitLabels() {
        if labelWidths.isEmpty {
            labelWidths = [titleLabel, statsLabel, printLabel].map {
                let c = $0.widthAnchor.constraint(equalToConstant: 0)
                c.priority = .defaultHigh
                c.isActive = true
                return c
            }
        }
        for (label, c) in zip([titleLabel, statsLabel, printLabel], labelWidths) {
            c.constant = ceil(label.attributedStringValue.boundingRect(
                with: NSSize(width: 10_000, height: 100), options: [.usesLineFragmentOrigin]).width) + 4
        }
    }

    private var currentPlate: Plate? {
        let i = platePopup.indexOfSelectedItem
        return i <= 0 || i > plates.count ? nil : plates[i - 1]
    }

    private func updateInfo(plate: Plate?) {
        guard let result else { return }
        var title = info.title ?? (fileName as NSString).deletingPathExtension
        if let d = info.designer { title += " by \(d)" }
        titleLabel.stringValue = title
        defer { fitLabels() }

        let st = result.stats
        let tris = st.triangles >= 1_000_000 ? String(format: "%.1fM", Double(st.triangles) / 1e6)
            : st.triangles >= 1_000 ? String(format: "%.1fK", Double(st.triangles) / 1e3) : "\(st.triangles)"
        var stats: [InfoLine.Item] = []
        if let plate { stats.append(.init(icon: .symbol("square.on.square"), text: plate.name, help: "Plate")) }
        stats.append(.init(icon: .symbol("triangle"), text: tris, help: "Triangles"))
        stats.append(.init(icon: .symbol("cube"), text: "\(st.objects)", help: "Objects"))
        stats.append(.init(icon: .symbol("ruler"),
                           text: String(format: "%.1f × %.1f × %.1f mm", st.size.x, st.size.y, st.size.z),
                           help: "Size (W × D × H)"))
        statsLabel.attributedStringValue = InfoLine.make(stats, monospacedDigits: true)

        var print: [InfoLine.Item] = []
        if let p = info.printer { print.append(.init(icon: InfoLine.printerIcon(p), text: p, help: "Printer")) }
        if let n = info.nozzle { print.append(.init(icon: .custom(InfoLine.nozzle), text: n, help: "Nozzle")) }
        if let l = info.layerHeight { print.append(.init(icon: .symbol("square.3.layers.3d"), text: l, help: "Layer height")) }
        if !info.filaments.isEmpty {
            print.append(.init(icon: .custom(InfoLine.spool), text: info.filaments.prefix(3).joined(separator: ", "), help: "Filament"))
        }
        if let f = info.infill { print.append(.init(icon: .symbol("square.grid.3x3"), text: f, help: "Sparse infill")) }
        printLabel.attributedStringValue = InfoLine.make(print, monospacedDigits: false)
        printLabel.isHidden = print.isEmpty
    }
}
