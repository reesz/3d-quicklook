import AppKit

/// Builds compact "icon value · icon value" lines for the info panel.
enum InfoLine {
    enum Icon {
        case symbol(String)
        case custom((NSRect) -> Void)          // draws in the current color
        case badge(text: String, color: NSColor)
        case logo(file: String, color: NSColor?)   // bundled SVG; nil color = label color
    }

    struct Item {
        let icon: Icon
        let text: String
        let help: String
    }

    static let fontSize: CGFloat = 11
    /// Fallback location for logo SVGs when not running from the extension bundle (screenshot tool).
    static var logoDirectory: URL?

    static func make(_ items: [Item], monospacedDigits: Bool) -> NSAttributedString {
        let font: NSFont = monospacedDigits ? .monospacedDigitSystemFont(ofSize: fontSize, weight: .regular)
                                            : .systemFont(ofSize: fontSize)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.secondaryLabelColor]
        let out = NSMutableAttributedString()
        for (i, item) in items.enumerated() {
            if i > 0 { out.append(NSAttributedString(string: "    ", attributes: attrs)) }
            let a = NSTextAttachment()
            let img = image(item.icon)
            a.image = img
            a.bounds = CGRect(x: 0, y: (font.capHeight - img.size.height) / 2, width: img.size.width, height: img.size.height)
            out.append(NSAttributedString(attachment: a))
            var textAttrs = attrs
            textAttrs[.toolTip] = item.help
            out.append(NSAttributedString(string: " " + item.text, attributes: textAttrs))
        }
        return out
    }

    /// Images draw lazily, so dynamic colors follow light/dark appearance.
    private static func image(_ icon: Icon) -> NSImage {
        switch icon {
        case .symbol(let name):
            let cfg = NSImage.SymbolConfiguration(pointSize: fontSize, weight: .medium)
            guard let sym = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(cfg) else { return NSImage() }
            let size = sym.size
            return NSImage(size: size, flipped: false) { r in
                sym.draw(in: r)
                NSColor.secondaryLabelColor.set()
                r.fill(using: .sourceIn)
                return true
            }
        case .custom(let draw):
            return NSImage(size: NSSize(width: 12, height: 12), flipped: false) { r in
                NSColor.secondaryLabelColor.set()
                draw(r)
                return true
            }
        case .logo(let file, let color):
            guard let url = Bundle(for: BundleToken.self).url(forResource: file, withExtension: "svg")
                    ?? logoDirectory.map({ $0.appendingPathComponent(file + ".svg") }),
                  let svg = NSImage(contentsOf: url) else { return image(.symbol("printer")) }
            let side = fontSize + 2
            return NSImage(size: NSSize(width: side, height: side), flipped: false) { r in
                svg.draw(in: r)
                (color ?? NSColor.labelColor).set()
                r.fill(using: .sourceIn)
                return true
            }
        case .badge(let text, let color):
            let font = NSFont.systemFont(ofSize: 8, weight: .heavy)
            let t = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.white])
            let w = max(13, ceil(t.size().width) + 6)
            return NSImage(size: NSSize(width: w, height: 13), flipped: false) { r in
                color.setFill()
                NSBezierPath(roundedRect: r, xRadius: 3, yRadius: 3).fill()
                let ts = t.size()
                t.draw(at: NSPoint(x: (r.width - ts.width) / 2, y: (r.height - ts.height) / 2 + 0.5))
                return true
            }
        }
    }

    // MARK: Custom glyphs (12×12, y-up)

    /// Hotend nozzle: heater block, tapered cone, tip.
    static let nozzle: (NSRect) -> Void = { _ in
        NSBezierPath(roundedRect: NSRect(x: 1.5, y: 7.5, width: 9, height: 4), xRadius: 1, yRadius: 1).fill()
        let cone = NSBezierPath()
        cone.move(to: NSPoint(x: 3, y: 7.5))
        cone.line(to: NSPoint(x: 9, y: 7.5))
        cone.line(to: NSPoint(x: 6.9, y: 2.6))
        cone.line(to: NSPoint(x: 5.1, y: 2.6))
        cone.close()
        cone.fill()
        NSRect(x: 5.4, y: 0.8, width: 1.2, height: 1.8).fill()
    }

    /// Filament spool seen from the side: flange ring, wound filament, hub.
    static let spool: (NSRect) -> Void = { _ in
        let outer = NSBezierPath(ovalIn: NSRect(x: 0.75, y: 0.75, width: 10.5, height: 10.5))
        outer.lineWidth = 1.3
        outer.stroke()
        let wound = NSBezierPath(ovalIn: NSRect(x: 3, y: 3, width: 6, height: 6))
        wound.lineWidth = 2.2
        wound.stroke()
        NSBezierPath(ovalIn: NSRect(x: 5, y: 5, width: 2, height: 2)).fill()
    }

    // MARK: Printer brands

    private static func hex(_ v: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat(v >> 16 & 0xFF) / 255, green: CGFloat(v >> 8 & 0xFF) / 255,
                blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }

    /// Simple Icons glyphs (CC0) bundled in Logos/. Black brands use the label color for dark mode.
    private static let logos: [(keys: [String], file: String, color: NSColor?)] = [
        (["bambu"], "bambulab", hex(0x00AE42)),
        (["anycubic"], "anycubic", hex(0x476695)),
        (["elegoo"], "elegoo", nil),
        (["flashforge", "adventurer"], "flashforge", nil),
        (["voron"], "vorondesign", hex(0xED3023)),
        (["makerbot", "replicator"], "makerbot", hex(0xFF1E0D)),
    ]

    private static let brands: [(keys: [String], badge: String, color: NSColor)] = [
        (["bambu"], "BL", NSColor(srgbRed: 0.00, green: 0.68, blue: 0.26, alpha: 1)),
        (["prusa"], "P", NSColor(srgbRed: 0.98, green: 0.41, blue: 0.19, alpha: 1)),
        (["creality", "ender", "cr-10", "k1", "k2"], "C", NSColor(srgbRed: 0.10, green: 0.45, blue: 0.95, alpha: 1)),
        (["voron"], "V", NSColor(srgbRed: 0.88, green: 0.14, blue: 0.10, alpha: 1)),
        (["elegoo"], "E", NSColor(srgbRed: 0.12, green: 0.42, blue: 0.85, alpha: 1)),
        (["anycubic"], "A", NSColor(srgbRed: 0.10, green: 0.50, blue: 0.90, alpha: 1)),
        (["qidi"], "Q", NSColor(srgbRed: 0.20, green: 0.25, blue: 0.35, alpha: 1)),
        (["flashforge", "adventurer"], "FF", NSColor(srgbRed: 0.90, green: 0.20, blue: 0.20, alpha: 1)),
        (["sovol"], "S", NSColor(srgbRed: 0.95, green: 0.55, blue: 0.10, alpha: 1)),
        (["snapmaker"], "S", NSColor(srgbRed: 0.15, green: 0.15, blue: 0.15, alpha: 1)),
        (["artillery"], "A", NSColor(srgbRed: 0.30, green: 0.30, blue: 0.30, alpha: 1)),
        (["ultimaker"], "U", NSColor(srgbRed: 0.10, green: 0.35, blue: 0.75, alpha: 1)),
    ]

    static func printerIcon(_ name: String) -> Icon {
        let n = name.lowercased()
        for l in logos where l.keys.contains(where: { n.contains($0) }) {
            return .logo(file: l.file, color: l.color)
        }
        for b in brands where b.keys.contains(where: { n.contains($0) }) {
            return .badge(text: b.badge, color: b.color)
        }
        return .symbol("printer")
    }
}

private final class BundleToken {}
