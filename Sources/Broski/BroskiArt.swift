import AppKit

/// Broski, drawn in code so one character serves as the app icon, the menu-bar glyph,
/// and the panel avatar. Based on the sketch: messy black hair with purple and yellow
/// streaks, thin black shades, a smirk, a black jacket, and a crown.
enum BroskiArt {
    enum Palette {
        static let ink = NSColor(srgbRed: 0.08, green: 0.08, blue: 0.09, alpha: 1)
        static let purple = NSColor(srgbRed: 0.49, green: 0.30, blue: 1.00, alpha: 1)
        static let yellow = NSColor(srgbRed: 1.00, green: 0.83, blue: 0.05, alpha: 1)
        static let lime = NSColor(srgbRed: 0.38, green: 0.88, blue: 0.25, alpha: 1)
        static let skin = NSColor(srgbRed: 0.99, green: 0.88, blue: 0.80, alpha: 1)
        static let paper = NSColor(srgbRed: 1.00, green: 0.99, blue: 0.97, alpha: 1)
    }

    typealias Pt = (CGFloat, CGFloat)

    /// Maps the 100×100 y-down design grid into `rect` (AppKit is y-up).
    struct Grid {
        let rect: CGRect
        func p(_ pt: Pt) -> NSPoint {
            NSPoint(x: rect.minX + pt.0 / 100 * rect.width, y: rect.maxY - pt.1 / 100 * rect.height)
        }
        func u(_ v: CGFloat) -> CGFloat { v / 100 * rect.width }
        func shifted(_ dx: CGFloat, _ dy: CGFloat) -> Grid { Grid(rect: rect.offsetBy(dx: u(dx), dy: -u(dy))) }
    }

    // MARK: Shapes

    static let hairPoints: [Pt] = [
        (26, 58), (22, 48), (9, 44), (20, 37), (11, 26), (27, 27), (24, 11), (38, 20), (44, 3),
        (52, 17), (63, 5), (65, 20), (80, 11), (76, 27), (92, 27), (80, 36), (91, 46), (76, 46), (74, 57),
        // Bangs, pointing down over the forehead.
        (70, 46), (65, 52), (59, 44), (52, 51), (47, 43), (40, 50), (36, 42), (30, 48), (28, 44),
    ]

    static func polygon(_ g: Grid, _ pts: [Pt]) -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: g.p(pts[0]))
        for pt in pts.dropFirst() { path.line(to: g.p(pt)) }
        path.close()
        path.lineJoinStyle = .round
        return path
    }

    static func line(_ g: Grid, _ points: Pt...) -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: g.p(points[0]))
        for pt in points.dropFirst() { path.line(to: g.p(pt)) }
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        return path
    }

    static func oval(_ g: Grid, center c: Pt, rx: CGFloat, ry: CGFloat) -> NSBezierPath {
        let origin = g.p((c.0 - rx, c.1 + ry))
        return NSBezierPath(ovalIn: NSRect(x: origin.x, y: origin.y, width: g.u(rx * 2), height: g.u(ry * 2)))
    }

    static func face(_ g: Grid) -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: g.p((27, 50)))
        path.curve(to: g.p((52, 84)), controlPoint1: g.p((26, 70)), controlPoint2: g.p((38, 84)))
        path.curve(to: g.p((75, 50)), controlPoint1: g.p((66, 84)), controlPoint2: g.p((76, 68)))
        path.curve(to: g.p((27, 50)), controlPoint1: g.p((74, 30)), controlPoint2: g.p((28, 30)))
        path.close()
        return path
    }

    static func lenses(_ g: Grid, bold: Bool) -> [NSBezierPath] {
        let d: CGFloat = bold ? 1.5 : 0
        return [
            polygon(g, [(30 - d, 55.5), (47 + d / 2, 54.5), (46, 63 + d * 1.5), (32 - d, 64 + d * 1.5)]),
            polygon(g, [(53 - d / 2, 54.5), (71 + d, 55.5), (69.5 + d, 64 + d * 1.5), (54, 63 + d * 1.5)]),
        ]
    }

    static func smirk(_ g: Grid) -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: g.p((43, 73)))
        path.curve(to: g.p((60, 71.5)), controlPoint1: g.p((48, 77)), controlPoint2: g.p((55, 76)))
        path.line(to: g.p((62.5, 68.5)))
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        return path
    }

    static func jacket(_ g: Grid) -> NSBezierPath {
        polygon(g, [(6, 122), (12, 100), (28, 91), (42, 87), (50, 97), (60, 87), (74, 91), (90, 100), (96, 122)])
    }

    /// The sketch's outlined crown, rotated clockwise by `degrees` around its top-left corner.
    static func crown(_ g: Grid, at origin: Pt, scale k: CGFloat, degrees: CGFloat) -> NSBezierPath {
        let local: [Pt] = [(0, 14), (1, 3), (6, 8), (10, 0), (14, 8), (19, 3), (20, 14)]
        let r = degrees * .pi / 180
        return polygon(g, local.map { pt in
            (origin.0 + (pt.0 * cos(r) - pt.1 * sin(r)) * k, origin.1 + (pt.0 * sin(r) + pt.1 * cos(r)) * k)
        })
    }

    /// Four-point sparkle.
    static func sparkle(_ g: Grid, center c: Pt, r: CGFloat) -> NSBezierPath {
        let k = r * 0.16
        let path = NSBezierPath()
        path.move(to: g.p((c.0, c.1 - r)))
        path.curve(to: g.p((c.0 + r, c.1)), controlPoint1: g.p((c.0 + k, c.1 - k)), controlPoint2: g.p((c.0 + k, c.1 - k)))
        path.curve(to: g.p((c.0, c.1 + r)), controlPoint1: g.p((c.0 + k, c.1 + k)), controlPoint2: g.p((c.0 + k, c.1 + k)))
        path.curve(to: g.p((c.0 - r, c.1)), controlPoint1: g.p((c.0 - k, c.1 + k)), controlPoint2: g.p((c.0 - k, c.1 + k)))
        path.curve(to: g.p((c.0, c.1 - r)), controlPoint1: g.p((c.0 - k, c.1 - k)), controlPoint2: g.p((c.0 - k, c.1 - k)))
        path.close()
        return path
    }

    static func stroke(_ path: NSBezierPath, _ color: NSColor, _ width: CGFloat) {
        color.setStroke()
        path.lineWidth = width
        path.stroke()
    }

    static func fill(_ path: NSBezierPath, _ color: NSColor) {
        color.setFill()
        path.fill()
    }

    // MARK: Colour artwork

    /// The full-colour character. The grid is 100 units wide; shoulders run past the bottom edge.
    static func drawCharacter(in rect: CGRect, crowned: Bool, shoulders: Bool) {
        let g = Grid(rect: rect)
        let ink = g.u(2.2)
        // Misregistered purple under the black ink, like the sketch.
        let under = g.shifted(2.2, 1.8)

        if shoulders {
            fill(jacket(under), Palette.purple)
            fill(polygon(g, [(44, 78), (58, 78), (59, 92), (45, 92)]), Palette.skin)
            stroke(line(g, (45, 80), (45, 91)), Palette.ink, ink)
            stroke(line(g, (58, 80), (59, 91)), Palette.ink, ink)
            let j = jacket(g)
            fill(j, Palette.ink)
            stroke(j, Palette.ink, ink)
            stroke(line(g, (40, 86), (37, 80), (46, 84)), Palette.ink, ink * 1.4)  // collar
            stroke(line(g, (62, 86), (66, 80), (57, 84)), Palette.ink, ink * 1.4)
            stroke(line(g, (16, 101), (28, 95)), Palette.purple, g.u(2.4))
            stroke(line(g, (78, 96), (86, 101)), Palette.yellow, g.u(2))
        }

        fill(hairPath(under), Palette.purple)
        stroke(face(under), Palette.purple, ink)

        let ear = oval(g, center: (27, 63), rx: 4.5, ry: 6)
        fill(ear, Palette.skin)
        stroke(ear, Palette.ink, ink)
        let f = face(g)
        fill(f, Palette.skin)
        stroke(f, Palette.ink, ink)

        let hair = hairPath(g)
        fill(hair, Palette.ink)
        stroke(hair, Palette.ink, g.u(1.2))
        let streaks: [(Pt, Pt)] = [((31, 24), (37, 33)), ((49, 10), (51, 21)), ((68, 13), (66, 24))]
        for (a, b) in streaks { stroke(line(g, a, b), Palette.yellow, g.u(2.6)) }
        stroke(line(g, (80, 33), (86, 40)), Palette.purple, g.u(2.4))

        for lens in lenses(g, bold: false) {
            fill(lens, Palette.ink)
            stroke(lens, Palette.ink, g.u(1.6))
        }
        stroke(line(g, (46.5, 57.5), (53.5, 57.5)), Palette.ink, g.u(2))
        stroke(line(g, (30.5, 57.5), (25, 59)), Palette.ink, g.u(2))
        let glints: [(Pt, Pt)] = [((34.5, 57), (37.5, 60.5)), ((57, 57), (60, 60.5))]
        for (a, b) in glints { stroke(line(g, a, b), NSColor.white.withAlphaComponent(0.85), g.u(1.3)) }

        stroke(smirk(g), Palette.ink, g.u(2.2))

        if crowned {
            let c = crown(g, at: (66, 1), scale: 1.25, degrees: 16)
            fill(c, Palette.yellow)
            stroke(c, Palette.ink, g.u(1.6))
        }
    }

    static func hairPath(_ g: Grid) -> NSBezierPath { polygon(g, hairPoints) }

    /// Round sticker with the head, used in the floating panel. Readable on light and dark panels.
    static func avatar(diameter: CGFloat, crowned: Bool) -> NSImage {
        NSImage(size: NSSize(width: diameter, height: diameter), flipped: false) { rect in
            let disc = NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5))
            fill(disc, Palette.paper)
            NSGraphicsContext.saveGraphicsState()
            disc.addClip()
            // Zoom in on the face: it has to read at 30pt.
            let side = rect.width * 1.12
            let face = CGRect(x: rect.midX - side / 2, y: rect.midY - side * 0.52, width: side, height: side)
            drawCharacter(in: face, crowned: false, shoulders: true)
            NSGraphicsContext.restoreGraphicsState()
            stroke(disc, NSColor.black.withAlphaComponent(0.15), 1)
            if crowned {
                // Sits on the disc's edge like a sticker instead of being clipped by it.
                let c = crown(Grid(rect: rect), at: (58, 2), scale: 1.6, degrees: 20)
                fill(c, Palette.yellow)
                stroke(c, Palette.ink, max(1, rect.width * 0.035))
            }
            return true
        }
    }

    /// App icon on the macOS icon grid: an 824-unit rounded square inside a 1024 canvas.
    static func drawAppIcon(in canvas: CGRect) {
        let s = canvas.width / 1024
        let body = CGRect(x: canvas.minX + 100 * s, y: canvas.minY + 100 * s, width: 824 * s, height: 824 * s)
        let shape = NSBezierPath(roundedRect: body, xRadius: 185 * s, yRadius: 185 * s)

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
        shadow.shadowBlurRadius = 18 * s
        shadow.shadowOffset = NSSize(width: 0, height: -8 * s)
        shadow.set()
        fill(shape, Palette.paper)
        NSGraphicsContext.restoreGraphicsState()

        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        let g = Grid(rect: body)
        stroke(line(g, (9, 30), (13, 21), (16, 29), (19, 20), (22, 28)), Palette.lime, g.u(1.8))
        stroke(line(g, (6, 44), (13, 47)), Palette.purple, g.u(1.8))
        stroke(line(g, (7, 52), (13, 53)), Palette.purple, g.u(1.8))
        for (c, r) in [((14, 70) as Pt, CGFloat(6.5)), ((88, 66), 4.5)] {
            let star = sparkle(g, center: c, r: r)
            fill(star, Palette.yellow)
            stroke(star, Palette.ink, g.u(0.9))
        }
        let head = CGRect(x: body.minX + body.width * 0.10, y: body.maxY - body.height * 0.90,
                          width: body.width * 0.80, height: body.height * 0.80)
        drawCharacter(in: head, crowned: true, shoulders: true)
        NSGraphicsContext.restoreGraphicsState()

        stroke(shape, NSColor.black.withAlphaComponent(0.08), 2 * s)
    }

    // MARK: Menu bar

    /// Monochrome menu-bar glyph (template image). `talking` adds sound waves while a note is recorded.
    static func menuBarImage(talking: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: talking ? 25 : 18, height: 18), flipped: false) { _ in
            let g = Grid(rect: CGRect(x: 0, y: -0.5, width: 18, height: 18))
            let f = face(g)
            stroke(f, .black, 1.3)
            fill(hairPath(g), .black)
            // Clear a thin gap so the shades don't merge with the bangs at this size.
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(rect: NSRect(origin: g.p((28, 55)), size: NSSize(width: g.u(46), height: g.u(3.5)))).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            for lens in lenses(g, bold: true) { fill(lens, .black) }
            stroke(line(g, (46, 58), (54, 58)), .black, 1.1)
            stroke(smirk(g), .black, 1.0)
            if talking {
                for r: CGFloat in [2.6, 4.9] {
                    let arc = NSBezierPath()
                    arc.appendArc(withCenter: NSPoint(x: 18.5, y: 9), radius: r, startAngle: -45, endAngle: 45)
                    arc.lineCapStyle = .round
                    stroke(arc, .black, 1.3)
                }
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    // MARK: Export

    static func png(pixels: Int, draw: (CGRect) -> Void) -> Data? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        rep.size = NSSize(width: pixels, height: pixels)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        draw(CGRect(x: 0, y: 0, width: pixels, height: pixels))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    /// Writes AppIcon.iconset (for `iconutil`) plus a preview sheet into `directory`.
    static func exportIcons(to directory: URL) throws {
        let iconset = directory.appendingPathComponent("AppIcon.iconset", isDirectory: true)
        try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
        for base in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
                if let data = png(pixels: base * scale, draw: drawAppIcon) {
                    try data.write(to: iconset.appendingPathComponent(name))
                }
            }
        }
        if let preview = png(pixels: 1024, draw: drawPreviewSheet) {
            try preview.write(to: directory.appendingPathComponent("preview.png"))
        }
    }

    /// Icon, avatar, and menu-bar glyphs side by side, for checking the art.
    static func drawPreviewSheet(in rect: CGRect) {
        fill(NSBezierPath(rect: rect), NSColor(white: 0.93, alpha: 1))
        drawAppIcon(in: CGRect(x: 0, y: 360, width: 660, height: 660))
        avatar(diameter: 160, crowned: false).draw(in: CGRect(x: 690, y: 760, width: 160, height: 160))
        avatar(diameter: 160, crowned: true).draw(in: CGRect(x: 690, y: 560, width: 160, height: 160))
        for (i, bar) in [NSColor(white: 0.98, alpha: 1), NSColor(white: 0.16, alpha: 1)].enumerated() {
            let strip = CGRect(x: 40, y: 200 - CGFloat(i) * 150, width: 944, height: 120)
            fill(NSBezierPath(roundedRect: strip, xRadius: 16, yRadius: 16), bar)
            let tint = i == 0 ? NSColor.black : NSColor.white
            for (j, talking) in [false, true].enumerated() {
                let glyph = menuBarImage(talking: talking)
                let size = NSSize(width: glyph.size.width * 5, height: glyph.size.height * 5)
                let tinted = NSImage(size: size, flipped: false) { r in
                    glyph.draw(in: r)
                    tint.set()
                    r.fill(using: .sourceAtop)
                    return true
                }
                tinted.draw(in: CGRect(x: 80 + CGFloat(j) * 220, y: strip.minY + 15, width: size.width, height: size.height))
                let small = NSImage(size: glyph.size, flipped: false) { r in
                    glyph.draw(in: r)
                    tint.set()
                    r.fill(using: .sourceAtop)
                    return true
                }
                small.draw(in: CGRect(x: 600 + CGFloat(j) * 80, y: strip.minY + 42, width: glyph.size.width * 2, height: glyph.size.height * 2))
            }
        }
    }
}
