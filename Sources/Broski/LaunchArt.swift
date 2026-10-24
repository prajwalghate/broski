import AppKit
import BroskiCore
import SwiftUI

/// `Broski --export-launch-art <dir>` draws the launch-stream thumbnails from the same character
/// and panel code as the app, so the art always matches what people download.
@MainActor
enum LaunchArt {
    static let size = CGSize(width: 1920, height: 1080)

    enum Color {
        static let night = NSColor(srgbRed: 0.016, green: 0.024, blue: 0.055, alpha: 1)
        static let navy = NSColor(srgbRed: 0.04, green: 0.08, blue: 0.17, alpha: 1)
        static let cyan = NSColor(srgbRed: 0.22, green: 0.91, blue: 1.00, alpha: 1)
        static let purple = BroskiArt.Palette.purple
        static let yellow = BroskiArt.Palette.yellow
        static let red = NSColor(srgbRed: 1.00, green: 0.18, blue: 0.27, alpha: 1)
    }

    static func export(to dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let panel = panelImage()
        let art: [(String, (CGRect) -> Void)] = [
            ("thumbnail-1-i-made-jarvis", { drawJarvis(in: $0, panel: panel, live: true) }),
            ("thumbnail-1-i-made-jarvis-replay", { drawJarvis(in: $0, panel: panel, live: false) }),
            ("thumbnail-2-never-forgets", { drawNeverForgets(in: $0, panel: panel, live: true) }),
            ("thumbnail-2-never-forgets-replay", { drawNeverForgets(in: $0, panel: panel, live: false) }),
            ("thumbnail-3-building-live", { drawBuildingLive(in: $0) }),
        ]
        for (name, draw) in art {
            guard let rep = render(draw) else { continue }
            try rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9])?.write(to: dir.appendingPathComponent(name + ".jpg"))
            try rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent(name + ".png"))
        }
    }

    private static func render(_ draw: (CGRect) -> Void) -> NSBitmapImageRep? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        draw(CGRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    // MARK: Thumbnails

    /// "I MADE JARVIS": the hook, with Broski as the glowing core.
    private static func drawJarvis(in rect: CGRect, panel: NSImage?, live showLive: Bool) {
        background(rect)
        let core = NSPoint(x: 1395, y: 560)
        hud(center: core, radius: 330)
        plate(center: core, radius: 250)
        character(center: core, radius: 250)
        hudLabels(around: core, radius: 330)

        _ = panel
        if showLive { live(at: NSPoint(x: 96, y: 930)) }
        text("I MADE", at: NSPoint(x: 90, y: 690), size: 160, weight: .black, color: .white, glow: nil)
        text("JARVIS", at: NSPoint(x: 80, y: 330), size: 360, weight: .black, color: Color.cyan, glow: Color.cyan, width: .compressed)
        text("for every idea on my Mac", at: NSPoint(x: 96, y: 230), size: 62, weight: .bold, color: NSColor.white.withAlphaComponent(0.85), glow: nil)
    }

    /// "MY MAC NEVER FORGETS": the product promise, with the real panel as proof.
    private static func drawNeverForgets(in rect: CGRect, panel: NSImage?, live showLive: Bool) {
        background(rect)
        let core = NSPoint(x: 400, y: 470)
        hud(center: core, radius: 300)
        plate(center: core, radius: 225)
        character(center: core, radius: 225)

        text("MY MAC", at: NSPoint(x: 820, y: 820), size: 150, weight: .black, color: .white, glow: nil)
        text("NEVER FORGETS", at: NSPoint(x: 812, y: 650), size: 170, weight: .black, color: Color.cyan, glow: Color.cyan, width: .compressed)
        if let panel {
            let w: CGFloat = 900
            let h = w * panel.size.height / panel.size.width
            glowImage(panel, in: CGRect(x: 880, y: 600 - h - 30, width: w, height: h), glow: Color.cyan)
        }
        if showLive { live(at: NSPoint(x: 96, y: 930)) }
    }

    /// "BUILDING JARVIS LIVE": for the dev stream before the launch.
    private static func drawBuildingLive(in rect: CGRect) {
        background(rect)
        codeRain(rect)
        let core = NSPoint(x: 1450, y: 540)
        hud(center: core, radius: 320)
        plate(center: core, radius: 240)
        character(center: core, radius: 240)
        hudLabels(around: core, radius: 320)

        text("BUILDING", at: NSPoint(x: 90, y: 660), size: 150, weight: .black, color: .white, glow: nil)
        text("JARVIS", at: NSPoint(x: 80, y: 380), size: 300, weight: .black, color: Color.cyan, glow: Color.cyan, width: .compressed)
        text("LIVE", at: NSPoint(x: 96, y: 200), size: 150, weight: .black, color: Color.yellow, glow: Color.yellow)
    }

    // MARK: Pieces

    private static func background(_ rect: CGRect) {
        Color.night.setFill()
        rect.fill()
        NSGradient(colors: [Color.navy, Color.night])?.draw(in: NSBezierPath(rect: rect), relativeCenterPosition: NSPoint(x: 0.35, y: 0))
        // A faint grid, like a HUD's backplate.
        let grid = NSBezierPath()
        stride(from: CGFloat(0), through: rect.width, by: 60).forEach { grid.move(to: NSPoint(x: $0, y: 0)); grid.line(to: NSPoint(x: $0, y: rect.height)) }
        stride(from: CGFloat(0), through: rect.height, by: 60).forEach { grid.move(to: NSPoint(x: 0, y: $0)); grid.line(to: NSPoint(x: rect.width, y: $0)) }
        Color.cyan.withAlphaComponent(0.05).setStroke()
        grid.lineWidth = 1
        grid.stroke()
        // Vignette.
        NSGradient(colors: [NSColor.clear, NSColor.black.withAlphaComponent(0.55)])?
            .draw(in: NSBezierPath(rect: rect), relativeCenterPosition: .zero)
    }

    private static func withGlow(_ color: NSColor, blur: CGFloat, _ body: () -> Void) {
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = color
        shadow.shadowBlurRadius = blur
        shadow.shadowOffset = .zero
        shadow.set()
        body()
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func arc(_ c: NSPoint, _ r: CGFloat, _ from: CGFloat, _ to: CGFloat, width: CGFloat, color: NSColor) {
        let path = NSBezierPath()
        path.appendArc(withCenter: c, radius: r, startAngle: from, endAngle: to)
        path.lineWidth = width
        path.lineCapStyle = .round
        color.setStroke()
        path.stroke()
    }

    /// Concentric arcs and tick rings around the core.
    private static func hud(center c: NSPoint, radius r: CGFloat) {
        withGlow(Color.cyan, blur: 28) {
            arc(c, r, 20, 160, width: 6, color: Color.cyan)
            arc(c, r, 200, 320, width: 6, color: Color.cyan)
            arc(c, r + 34, 100, 250, width: 3, color: Color.cyan.withAlphaComponent(0.7))
            arc(c, r + 34, 290, 410, width: 3, color: Color.cyan.withAlphaComponent(0.7))
            arc(c, r - 36, 0, 360, width: 2, color: Color.cyan.withAlphaComponent(0.35))
            arc(c, r + 70, 60, 120, width: 10, color: Color.purple)
            arc(c, r + 70, 240, 275, width: 10, color: Color.yellow)
        }
        let ticks = NSBezierPath()
        for i in 0..<120 {
            let a = CGFloat(i) * 3 * .pi / 180
            let long = i % 5 == 0
            let r1 = r + 52, r2 = r + (long ? 64 : 58)
            ticks.move(to: NSPoint(x: c.x + cos(a) * r1, y: c.y + sin(a) * r1))
            ticks.line(to: NSPoint(x: c.x + cos(a) * r2, y: c.y + sin(a) * r2))
        }
        ticks.lineWidth = 2
        Color.cyan.withAlphaComponent(0.55).setStroke()
        ticks.stroke()
    }

    /// The bright disc Broski sits on, so the black ink reads on a dark background.
    private static func plate(center c: NSPoint, radius r: CGFloat) {
        let disc = NSBezierPath(ovalIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
        withGlow(Color.cyan, blur: 90) {
            BroskiArt.Palette.paper.setFill()
            disc.fill()
        }
        NSGradient(colors: [BroskiArt.Palette.paper, NSColor(srgbRed: 0.80, green: 0.95, blue: 1, alpha: 1)])?
            .draw(in: disc, relativeCenterPosition: NSPoint(x: 0, y: 0.3))
        disc.lineWidth = 8
        Color.cyan.setStroke()
        disc.stroke()
    }

    private static func character(center c: NSPoint, radius r: CGFloat) {
        let disc = NSBezierPath(ovalIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
        NSGraphicsContext.saveGraphicsState()
        disc.addClip()
        let side = r * 2.15
        BroskiArt.drawCharacter(in: CGRect(x: c.x - side / 2, y: c.y - side * 0.56, width: side, height: side), crowned: false, shoulders: true)
        NSGraphicsContext.restoreGraphicsState()
        // The crown sits on the rim, outside the circle, like the panel avatar's.
        let g = BroskiArt.Grid(rect: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
        let crown = BroskiArt.crown(g, at: (60, -4), scale: 1.7, degrees: 18)
        withGlow(Color.yellow.withAlphaComponent(0.8), blur: 40) {
            BroskiArt.Palette.yellow.setFill()
            crown.fill()
        }
        crown.lineWidth = r * 0.03
        BroskiArt.Palette.ink.setStroke()
        crown.stroke()
    }

    private static func hudLabels(around c: NSPoint, radius r: CGFloat) {
        let labels: [(String, CGFloat)] = [("VOICE · ONLINE", 52), ("WHISPER · ON-DEVICE", 128), ("MEMORY · 100%", 222), ("NOTES FILED · AUTO", 312)]
        for (label, degrees) in labels {
            let a = degrees * .pi / 180
            let p = NSPoint(x: c.x + cos(a) * (r + 105), y: c.y + sin(a) * (r + 105))
            let left = cos(a) < 0
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 22, weight: .bold),
                .foregroundColor: Color.cyan.withAlphaComponent(0.9),
                .kern: 2,
            ]
            let s = NSAttributedString(string: label, attributes: attrs)
            var x = left ? p.x - s.size().width : p.x
            x = min(max(x, 40), size.width - s.size().width - 40)
            s.draw(at: NSPoint(x: x, y: p.y - 11))
        }
    }

    private static func live(at p: NSPoint) {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 44, weight: .heavy), .foregroundColor: NSColor.white, .kern: 3]
        let s = NSAttributedString(string: "LIVE", attributes: attrs)
        let box = CGRect(x: p.x, y: p.y, width: s.size().width + 92, height: 72)
        withGlow(Color.red, blur: 30) {
            Color.red.setFill()
            NSBezierPath(roundedRect: box, xRadius: 14, yRadius: 14).fill()
        }
        NSColor.white.setFill()
        NSBezierPath(ovalIn: CGRect(x: box.minX + 26, y: box.midY - 11, width: 22, height: 22)).fill()
        s.draw(at: NSPoint(x: box.minX + 62, y: box.midY - s.size().height / 2))
    }

    private static func text(_ string: String, at p: NSPoint, size: CGFloat, weight: NSFont.Weight, color: NSColor,
                             glow: NSColor?, width: NSFont.Width = .standard) {
        let font = NSFont.systemFont(ofSize: size, weight: weight, width: width)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .kern: size * -0.01]
        let s = NSAttributedString(string: string, attributes: attrs)
        // A dark outline keeps the words readable when the thumbnail is tiny.
        withGlow(NSColor.black.withAlphaComponent(0.9), blur: 18) { s.draw(at: p) }
        if let glow { withGlow(glow.withAlphaComponent(0.85), blur: 40) { s.draw(at: p) } }
        s.draw(at: p)
    }

    private static func glowImage(_ image: NSImage, in rect: CGRect, glow: NSColor) {
        withGlow(glow.withAlphaComponent(0.7), blur: 50) {
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 8, dy: 8), xRadius: 30, yRadius: 30).fill()
        }
        image.draw(in: rect)
    }

    private static func codeRain(_ rect: CGRect) {
        let lines = [
            "let text = try await whisper.transcribe(phrase)",
            "brain.interpret(text) → strado · bug",
            "engine.drainRecording()  // never cut you off",
            "store.create(note)  ✓ saved",
            "SelectionGrabber.grab() → “highlighted text”",
            "panel.present(focus: true)",
        ]
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 26, weight: .medium),
            .foregroundColor: Color.cyan.withAlphaComponent(0.06),
        ]
        for (i, line) in lines.enumerated() {
            NSAttributedString(string: line, attributes: attrs).draw(at: NSPoint(x: 70 + CGFloat(i % 2) * 60, y: 110 + CGFloat(i) * 150))
        }
    }

    // MARK: The real panel

    private static func panelImage() -> NSImage? {
        let model = PanelModel()
        model.whisperState = .ready
        model.aiEnabled = true
        model.phase = .typing
        model.text = "In the strado project, add a bug: the login button overlaps the logo when the window is narrow"
        model.context = ItemContext(app: "Brave Browser", window: "Strado — Sign in", url: "https://staging.strado.app/login")
        model.proposal = Interpretation(project: "strado", kind: "bug", title: "Login button overlaps the logo on narrow windows")
        let view = PanelView(model: model)
            .background(RoundedRectangle(cornerRadius: 18).fill(SwiftUI.Color(nsColor: NSColor(srgbRed: 0.13, green: 0.13, blue: 0.15, alpha: 1))))
            .environment(\.colorScheme, .dark)
        let hosting = NSHostingView(rootView: view)
        hosting.appearance = NSAppearance(named: .darkAqua)
        // The panel sizes itself to what it shows (a two-line plan is taller), so the image does too.
        let height = PanelView.height(for: model)
        hosting.frame = CGRect(x: 0, y: 0, width: PanelView.width, height: height)
        hosting.layoutSubtreeIfNeeded()
        let scale: CGFloat = 3
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(PanelView.width * scale), pixelsHigh: Int(height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = hosting.frame.size
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        let image = NSImage(size: hosting.frame.size)
        image.addRepresentation(rep)
        return image
    }
}
