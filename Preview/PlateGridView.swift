import AppKit

/// A grid of per-plate close-up renders. Tiles shrink to fit; clicking one opens that plate.
final class PlateGridView: NSView {
    var onSelect: ((Int) -> Void)?             // plate position (0-based)
    var contentInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12) { didSet { needsLayout = true } }
    private(set) var tiles: [Tile] = []

    final class Tile: NSView {
        let imageView = NSImageView()
        let label = NSTextField(labelWithString: "")
        let spinner = NSProgressIndicator()
        var index = 0
        weak var grid: PlateGridView?
        private var tracking: NSTrackingArea?
        private var hovered = false { didSet { updateColors() } }

        init(title: String) {
            super.init(frame: .zero)
            wantsLayer = true
            layer?.cornerRadius = 10
            layer?.borderWidth = 1
            imageView.imageScaling = .scaleProportionallyUpOrDown
            label.stringValue = title
            label.font = .systemFont(ofSize: 11, weight: .medium)
            label.textColor = .secondaryLabelColor
            label.lineBreakMode = .byTruncatingTail
            label.alignment = .center
            spinner.style = .spinning
            spinner.controlSize = .small
            spinner.startAnimation(nil)
            [imageView, label, spinner].forEach(addSubview)
            toolTip = title
            updateColors()
        }
        required init?(coder: NSCoder) { fatalError() }

        override func layout() {
            super.layout()
            let b = bounds
            label.frame = NSRect(x: 8, y: 6, width: b.width - 16, height: 16)
            imageView.frame = NSRect(x: 4, y: 24, width: b.width - 8, height: b.height - 28)
            spinner.frame = NSRect(x: b.midX - 8, y: b.midY - 8, width: 16, height: 16)
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let t = tracking { removeTrackingArea(t) }
            tracking = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                      owner: self, userInfo: nil)
            addTrackingArea(tracking!)
        }
        override func mouseEntered(with event: NSEvent) { hovered = true }
        override func mouseExited(with event: NSEvent) { hovered = false }
        override func mouseUp(with event: NSEvent) { grid?.onSelect?(index) }
        override func viewDidChangeEffectiveAppearance() { updateColors() }

        func setImage(_ image: NSImage?) {
            imageView.image = image
            spinner.stopAnimation(nil)
            spinner.isHidden = true
        }

        private func updateColors() {
            effectiveAppearance.performAsCurrentDrawingAppearance {
                let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                layer?.backgroundColor = NSColor(white: dark ? 1 : 0, alpha: hovered ? 0.09 : 0.04).cgColor
                layer?.borderColor = (hovered ? NSColor.controlAccentColor : NSColor(white: dark ? 1 : 0, alpha: 0.08)).cgColor
            }
        }
    }

    func setPlates(_ titles: [String]) {
        tiles.forEach { $0.removeFromSuperview() }
        tiles = titles.enumerated().map { i, t in
            let tile = Tile(title: t)
            tile.index = i
            tile.grid = self
            addSubview(tile)
            return tile
        }
        needsLayout = true
    }

    /// Picks the column count that makes tiles as large as possible (tiles ~4:3).
    override func layout() {
        super.layout()
        let n = tiles.count
        guard n > 0 else { return }
        let area = NSRect(x: contentInsets.left, y: contentInsets.bottom,
                          width: bounds.width - contentInsets.left - contentInsets.right,
                          height: bounds.height - contentInsets.top - contentInsets.bottom)
        let gap: CGFloat = 10
        var best = (cols: 1, w: CGFloat(0), h: CGFloat(0))
        for cols in 1...n {
            let rows = Int(ceil(Double(n) / Double(cols)))
            var w = (area.width - gap * CGFloat(cols - 1)) / CGFloat(cols)
            var h = (area.height - gap * CGFloat(rows - 1)) / CGFloat(rows)
            if w / h > 4.0 / 3.0 { w = h * 4 / 3 } else { h = w * 3 / 4 }
            if w > best.w { best = (cols, w, h) }
        }
        let cols = best.cols, rows = Int(ceil(Double(n) / Double(cols)))
        let totalH = best.h * CGFloat(rows) + gap * CGFloat(rows - 1)
        let top = area.maxY - (area.height - totalH) / 2
        for (i, tile) in tiles.enumerated() {
            let r = i / cols, c = i % cols
            let inRow = min(cols, n - r * cols)          // center the last row
            let rowW = best.w * CGFloat(inRow) + gap * CGFloat(inRow - 1)
            let x = area.minX + (area.width - rowW) / 2 + CGFloat(c) * (best.w + gap)
            let y = top - CGFloat(r + 1) * best.h - CGFloat(r) * gap
            tile.frame = NSRect(x: x, y: y, width: best.w, height: best.h).integral
        }
    }

    var tileSize: CGSize { tiles.first?.imageView.bounds.size ?? .zero }
}
