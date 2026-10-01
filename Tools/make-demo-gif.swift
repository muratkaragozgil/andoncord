import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Renders a faithful demo of the AndonCord notch panel, frame by frame, into an
// animated GIF. Not a screen capture (the build environment has no
// screen-recording permission) — every pixel is drawn from the same palette,
// geometry, and equalizer math the real app uses, so it mirrors what the app
// renders. The story: four Claude Code sessions running at once under the live
// quota strip, then one of them pulls the cord on a shell command.
//
// Run with `swift Tools/make-demo-gif.swift docs/demo.gif`.

// MARK: - Palette (mirrors AndonTheme)

func C(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
    CGColor(srgbRed: r, green: g, blue: b, alpha: a)
}
let void = C(0.039, 0.035, 0.031)
let surface = C(0.086, 0.078, 0.067)
let surfaceRaised = C(0.129, 0.118, 0.098)
let hairline = C(0.20, 0.184, 0.153)
let textPrimary = C(0.949, 0.929, 0.890)
let textSecondary = C(0.651, 0.620, 0.557)
let textTertiary = C(0.431, 0.404, 0.353)
let amber = C(0.910, 0.639, 0.239)
let green = C(0.341, 0.780, 0.498)
let red = C(0.898, 0.329, 0.294)
let inactive = C(0.290, 0.267, 0.227)

func nscolor(_ c: CGColor) -> NSColor { NSColor(cgColor: c) ?? .white }

let W = 760, H = 520
let scale = 2
let pxW = W * scale, pxH = H * scale

func rTL(_ x: CGFloat, _ top: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
    CGRect(x: x, y: CGFloat(H) - top - h, width: w, height: h)
}
func roundedPath(_ r: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
}
func notchPath(_ r: CGRect, _ radius: CGFloat) -> CGPath {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: r.minX, y: r.maxY))
    p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
    p.addLine(to: CGPoint(x: r.maxX, y: r.minY + radius))
    p.addQuadCurve(to: CGPoint(x: r.maxX - radius, y: r.minY), control: CGPoint(x: r.maxX, y: r.minY))
    p.addLine(to: CGPoint(x: r.minX + radius, y: r.minY))
    p.addQuadCurve(to: CGPoint(x: r.minX, y: r.minY + radius), control: CGPoint(x: r.minX, y: r.minY))
    p.closeSubpath()
    return p
}
func text(_ ctx: CGContext, _ s: String, _ x: CGFloat, _ top: CGFloat,
          size: CGFloat, color: CGColor, weight: NSFont.Weight = .regular,
          mono: Bool = false, tracking: CGFloat = 0) {
    let font = mono ? NSFont.monospacedSystemFont(ofSize: size, weight: weight)
                    : NSFont.systemFont(ofSize: size, weight: weight)
    let str = NSAttributedString(string: s, attributes: [
        .font: font, .foregroundColor: nscolor(color), .kern: tracking])
    let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = ns
    str.draw(at: NSPoint(x: x, y: CGFloat(H) - top - size * 1.15))
    NSGraphicsContext.restoreGraphicsState()
}
func tw(_ s: String, size: CGFloat, weight: NSFont.Weight = .regular, mono: Bool = false) -> CGFloat {
    let font = mono ? NSFont.monospacedSystemFont(ofSize: size, weight: weight)
                    : NSFont.systemFont(ofSize: size, weight: weight)
    return NSAttributedString(string: s, attributes: [.font: font]).size().width
}

// MARK: - Components

func equalizer(_ ctx: CGContext, cx: CGFloat, cy: CGFloat, size: CGFloat, t: Double, color: CGColor) {
    let barW = size * 0.22, sp = size * 0.17
    let total = barW * 3 + sp * 2
    var x = cx - total / 2
    ctx.saveGState(); ctx.setShadow(offset: .zero, blur: 4, color: color.copy(alpha: 0.5))
    for ph in [0.0, 1.1, 2.2] {
        let h = size * (0.32 + 0.68 * (0.5 + 0.5 * sin(t * 7 + ph)))
        ctx.setFillColor(color)
        ctx.addPath(CGPath(roundedRect: CGRect(x: x, y: cy - h / 2, width: barW, height: h),
                           cornerWidth: barW / 2, cornerHeight: min(barW / 2, h / 2), transform: nil))
        ctx.fillPath(); x += barW + sp
    }
    ctx.restoreGState()
}
func dot(_ ctx: CGContext, cx: CGFloat, cy: CGFloat, size: CGFloat, color: CGColor, glow: CGFloat = 0.5) {
    ctx.saveGState(); ctx.setShadow(offset: .zero, blur: 4, color: color.copy(alpha: glow))
    ctx.setFillColor(color)
    ctx.addPath(CGPath(roundedRect: CGRect(x: cx - size / 2, y: cy - size / 2, width: size, height: size),
                       cornerWidth: size * 0.3, cornerHeight: size * 0.3, transform: nil))
    ctx.fillPath(); ctx.restoreGState()
}
func pillButton(_ ctx: CGContext, _ label: String, x: CGFloat, top: CGFloat,
                tint: CGColor, prominent: Bool, highlight: Bool = false) -> CGFloat {
    let padH: CGFloat = 12, fs: CGFloat = 12
    let w = tw(label, size: fs, weight: .semibold) + padH * 2, h: CGFloat = 28
    let r = rTL(x, top, w, h)
    ctx.setFillColor(prominent ? tint : tint.copy(alpha: highlight ? 0.30 : 0.16)!)
    ctx.addPath(roundedPath(r, 7)); ctx.fillPath()
    if !prominent {
        ctx.setStrokeColor(tint.copy(alpha: 0.35)!); ctx.setLineWidth(1)
        ctx.addPath(roundedPath(r.insetBy(dx: 0.5, dy: 0.5), 7)); ctx.strokePath()
    }
    text(ctx, label, x + padH, top + (h - fs) / 2 - 1, size: fs,
         color: prominent ? void : tint, weight: .semibold)
    return w
}

/// One session row on the board.
func sessionRow(_ ctx: CGContext, x: CGFloat, top: CGFloat, width: CGFloat, t: Double,
                title: String, terminal: String, seconds: Int, cord: Bool, status: String) {
    let cy = CGFloat(H) - top - 23
    if cord {
        let blink = sin(t * 7) > 0 ? 1.0 : 0.55
        dot(ctx, cx: x + 15, cy: cy, size: 9, color: amber, glow: 0.9 * blink)
    } else {
        equalizer(ctx, cx: x + 16, cy: cy, size: 12, t: t, color: green)
    }
    text(ctx, title, x + 30, top + 9, size: 12, color: textPrimary, weight: .medium)
    let timeLabel = "\(seconds)s"
    let timeW = tw(timeLabel, size: 10, mono: true)
    text(ctx, timeLabel, x + width - 14 - timeW, top + 10, size: 10,
         color: cord ? amber : green, weight: .medium, mono: true)
    let termW = tw(terminal, size: 9)
    text(ctx, terminal, x + width - 14 - timeW - 10 - termW, top + 11, size: 9, color: textTertiary)
    text(ctx, status, x + 30, top + 25, size: 10.5, color: cord ? amber : textSecondary)
}

/// The quota strip under the header — 5-hour and weekly windows, real feature.
func usageStrip(_ ctx: CGContext, x: CGFloat, top: CGFloat, width: CGFloat) {
    ctx.setFillColor(surface)
    ctx.fill(rTL(x, top, width, 26))
    ctx.setFillColor(hairline); ctx.fill(rTL(x, top, width, 1))
    let cy = CGFloat(H) - top - 13
    var cx = x + 16
    func window(_ label: String, _ fraction: Double, _ pct: String, _ reset: String) {
        text(ctx, label, cx, top + 8, size: 9, color: textTertiary, weight: .semibold, tracking: 0.5)
        cx += tw(label, size: 9, weight: .semibold) + 7
        let segs = 8, segW: CGFloat = 5, gap: CGFloat = 1.5, hgt: CGFloat = 7
        let lit = Int((Double(segs) * fraction).rounded(.up))
        for i in 0..<segs {
            ctx.setFillColor(i < lit ? green : inactive.copy(alpha: 0.5)!)
            ctx.addPath(CGPath(roundedRect: CGRect(x: cx, y: cy - hgt/2, width: segW, height: hgt),
                               cornerWidth: 1, cornerHeight: 1, transform: nil))
            ctx.fillPath(); cx += segW + gap
        }
        cx += 5
        text(ctx, pct, cx, top + 7, size: 10, color: green, weight: .semibold, mono: true)
        cx += tw(pct, size: 10, weight: .semibold, mono: true) + 6
        text(ctx, reset, cx, top + 8, size: 9, color: textTertiary, mono: true)
        cx += tw(reset, size: 9, mono: true) + 16
    }
    window("5H", 0.41, "41%", "3h12m")
    window("7D", 0.12, "12%", "4d2h")
    let cost = "$4.83"
    text(ctx, cost, x + width - 16 - tw(cost, size: 10, mono: true), top + 7,
         size: 10, color: textTertiary, mono: true)
}

// MARK: - Wallpaper

/// An original macOS-style desktop, drawn from scratch.
///
/// Deliberately *not* one of Apple's shipped wallpapers — those are copyrighted,
/// and this GIF lives in a public repo. This is a Sequoia-flavoured flowing
/// gradient of the same family (deep indigo through violet into warm magenta),
/// layered radial glows over a diagonal base, so it reads unmistakably as "a
/// Mac desktop" without redistributing anyone's artwork.
func drawWallpaper(_ ctx: CGContext) {
    let full = CGRect(x: 0, y: 0, width: W, height: H)

    // Diagonal base wash.
    if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: [C(0.16, 0.12, 0.32), C(0.09, 0.07, 0.20),
                                   C(0.05, 0.05, 0.13)] as CFArray,
                          locations: [0, 0.55, 1]) {
        ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: CGFloat(H)),
                               end: CGPoint(x: CGFloat(W), y: 0), options: [])
    }

    // Soft coloured glows, blended over the base like the aurora bands Apple's
    // gradients use. `.drawRadialGradient` fades each to transparent.
    func glow(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat, _ color: CGColor) {
        ctx.saveGState()
        ctx.setBlendMode(.plusLighter)
        if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                              colors: [color, color.copy(alpha: 0)!] as CFArray,
                              locations: [0, 1]) {
            ctx.drawRadialGradient(g, startCenter: CGPoint(x: cx, y: cy), startRadius: 0,
                                   endCenter: CGPoint(x: cx, y: cy), endRadius: r,
                                   options: [])
        }
        ctx.restoreGState()
    }
    glow(CGFloat(W) * 0.72, CGFloat(H) * 0.30, 460, C(0.62, 0.24, 0.55, 0.55))  // magenta
    glow(CGFloat(W) * 0.20, CGFloat(H) * 0.72, 420, C(0.20, 0.30, 0.72, 0.50))  // blue
    glow(CGFloat(W) * 0.50, CGFloat(H) * 0.05, 360, C(0.80, 0.42, 0.34, 0.32))  // warm horizon
    glow(CGFloat(W) * 0.92, CGFloat(H) * 0.85, 300, C(0.30, 0.14, 0.42, 0.45))  // violet corner

    // A gentle vignette so the panel's own shadow still reads.
    ctx.saveGState()
    if let v = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: [C(0, 0, 0, 0), C(0, 0, 0, 0.28)] as CFArray,
                          locations: [0.55, 1]) {
        ctx.drawRadialGradient(v, startCenter: CGPoint(x: CGFloat(W) / 2, y: CGFloat(H) / 2),
                               startRadius: 0,
                               endCenter: CGPoint(x: CGFloat(W) / 2, y: CGFloat(H) / 2),
                               endRadius: CGFloat(W) * 0.62, options: [])
    }
    ctx.restoreGState()
    _ = full
}

// MARK: - Frame

func ramp(_ t: Double, _ a: Double, _ b: Double) -> Double {
    if t <= a { return 0 }; if t >= b { return 1 }
    let x = (t - a) / (b - a); return x * x * (3 - 2 * x)
}

func drawFrame(_ ctx: CGContext, t: Double) {
    drawWallpaper(ctx)

    // Timeline (s): 0-1 idle | 1-1.4 expand | 1.4-4.6 four sessions working
    //   | 4.6 one pulls the cord | 5-7.4 permission card | 7.4-7.8 collapse
    let boardExpand = ramp(t, 1.0, 1.4) - ramp(t, 7.4, 7.7)
    let cordPulled = t >= 4.6 && t < 7.5
    let showCard = t >= 5.0 && t < 7.5

    let collapsedW: CGFloat = 340, expandedW: CGFloat = 470
    let w = collapsedW + (expandedW - collapsedW) * boardExpand
    let pillH: CGFloat = 40
    let cardExtra: CGFloat = showCard ? 176 : 0
    let boardH = pillH + (268 + cardExtra - pillH) * boardExpand
    let x = (CGFloat(W) - w) / 2
    let radius = 12 + 10 * boardExpand
    let panel = rTL(x, 0, w, boardH)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 22 * (0.4 + 0.6 * boardExpand), color: C(0, 0, 0, 0.55))
    ctx.setFillColor(void); ctx.addPath(notchPath(panel, radius)); ctx.fillPath()
    ctx.restoreGState()
    if boardExpand > 0.02 {
        ctx.setStrokeColor(hairline.copy(alpha: boardExpand)!); ctx.setLineWidth(1)
        ctx.addPath(notchPath(panel.insetBy(dx: 0.5, dy: 0.5), radius)); ctx.strokePath()
    }

    // ── Header / pill row ──
    let padL = x + 16
    let idle = t < 1.0
    if idle {
        dot(ctx, cx: padL + 4, cy: CGFloat(H) - pillH / 2, size: 8, color: red)
        text(ctx, "Idle", padL + 18, pillH / 2 - 6, size: 12, color: textTertiary, weight: .medium)
    } else {
        ctx.setFillColor(amber); ctx.fill(rTL(padL, pillH / 2 - 6, 3, 11))
        ctx.setFillColor(green); ctx.fill(rTL(padL + 5, pillH / 2 - 6, 3, 11))
        text(ctx, "ANDONCORD", padL + 14, pillH / 2 - 5, size: 10, color: textSecondary, weight: .semibold, tracking: 1.2)
        let count = cordPulled ? "1 waiting · 4 running" : "4 running"
        text(ctx, count, x + w - 16 - tw(count, size: 10, mono: true), pillH / 2 - 5, size: 10, color: textTertiary, mono: true)
    }

    guard boardExpand > 0.25 else { return }
    ctx.saveGState(); ctx.setAlpha(ramp(t, 1.3, 1.7))
    ctx.setFillColor(hairline); ctx.fill(rTL(x, pillH, w, 1))
    usageStrip(ctx, x: x, top: pillH + 1, width: w)

    var y = pillH + 27 + 8
    sessionRow(ctx, x: x, top: y, width: w, t: t,
               title: "fix auth in middleware.ts",
               terminal: "iTerm2", seconds: 12 + Int(t), cord: false,
               status: Int(t) % 2 == 0 ? "Edit(middleware.ts)" : "Thinking…")
    y += 46
    ctx.setFillColor(hairline.copy(alpha: 0.5)!); ctx.fill(rTL(x + 30, y - 2, w - 44, 1))
    sessionRow(ctx, x: x, top: y, width: w, t: t + 0.7,
               title: "add unit tests for parser",
               terminal: "Ghostty", seconds: 8 + Int(t), cord: false,
               status: Int(t) % 2 == 0 ? "Bash(npm test)" : "Thinking…")
    y += 46
    ctx.setFillColor(hairline.copy(alpha: 0.5)!); ctx.fill(rTL(x + 30, y - 2, w - 44, 1))
    sessionRow(ctx, x: x, top: y, width: w, t: t + 1.4,
               title: "migrate configs to v2",
               terminal: "Terminal", seconds: 21 + Int(t), cord: false,
               status: Int(t) % 2 == 0 ? "Read(config/v2.ts)" : "Thinking…")
    y += 46
    ctx.setFillColor(hairline.copy(alpha: 0.5)!); ctx.fill(rTL(x + 30, y - 2, w - 44, 1))
    sessionRow(ctx, x: x, top: y, width: w, t: t + 2.1,
               title: "ship the staging build",
               terminal: "WezTerm", seconds: 33 + Int(t), cord: cordPulled,
               status: cordPulled ? "Waiting on you — Bash(npm run deploy)"
                   : (Int(t) % 2 == 0 ? "Bash(npm run build)" : "Thinking…"))
    y += 48
    ctx.restoreGState()

    // ── Permission card ──
    if showCard {
        let ca = ramp(t, 5.2, 5.6) * (1 - ramp(t, 7.3, 7.55))
        ctx.saveGState(); ctx.setAlpha(ca)
        ctx.setFillColor(hairline); ctx.fill(rTL(x, y, w, 1))
        let cardTop = y + 1
        ctx.setFillColor(amber.copy(alpha: 0.07)!); ctx.fill(rTL(x, cardTop, w, boardH - cardTop - 4))
        ctx.setFillColor(amber.copy(alpha: 0.9)!); ctx.fill(rTL(x, cardTop, 2, boardH - cardTop - 4))

        var cy = cardTop + 11
        dot(ctx, cx: x + 20, cy: CGFloat(H) - cy - 8, size: 7, color: amber, glow: 0.9)
        text(ctx, "CORD PULLED · PERMISSION", x + 30, cy + 3, size: 10, color: amber, weight: .semibold, tracking: 0.8)
        let cardTitle = "ship the staging build"
        text(ctx, cardTitle, x + w - 16 - tw(cardTitle, size: 10), cy + 3, size: 10, color: textTertiary)
        cy += 25
        text(ctx, "Bash", x + 16, cy, size: 13, color: textPrimary, weight: .semibold)
        text(ctx, "npm run deploy", x + 16 + tw("Bash ", size: 13, weight: .semibold), cy + 1,
             size: 11, color: textSecondary, mono: true)
        cy += 23
        let box = rTL(x + 16, cy, w - 32, 30)
        ctx.setFillColor(surface); ctx.addPath(roundedPath(box, 6)); ctx.fillPath()
        text(ctx, "npm run deploy", x + 24, cy + 8, size: 11, color: textPrimary, mono: true)
        cy += 44
        let dw = pillButton(ctx, "Deny", x: x + 16, top: cy, tint: red, prominent: false)
        _ = pillButton(ctx, "Allow", x: x + 16 + dw + 8, top: cy, tint: green, prominent: true,
                       highlight: t >= 6.9 && t < 7.3)
        text(ctx, "⌘Y / ⌘N", x + w - 16 - tw("⌘Y / ⌘N", size: 9, mono: true), cy + 8, size: 9, color: textTertiary, mono: true)
        ctx.restoreGState()
    }
}

// MARK: - Render GIF

let fps = 18
let duration = 8.0
let frameCount = Int(duration * Double(fps))
let delay = 1.0 / Double(fps)

let outURL = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/andon-demo.gif")
guard let dest = CGImageDestinationCreateWithURL(outURL as CFURL, UTType.gif.identifier as CFString, frameCount, nil) else {
    fatalError("cannot create gif")
}
CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary as String:
    [kCGImagePropertyGIFLoopCount as String: 0]] as CFDictionary)
let frameProps = [kCGImagePropertyGIFDictionary as String: [kCGImagePropertyGIFDelayTime as String: delay]]
let cs = CGColorSpaceCreateDeviceRGB()
for i in 0..<frameCount {
    let t = Double(i) / Double(fps)
    guard let ctx = CGContext(data: nil, width: pxW, height: pxH, bitsPerComponent: 8, bytesPerRow: 0,
                              space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
    ctx.scaleBy(x: CGFloat(scale), y: CGFloat(scale)); ctx.setShouldAntialias(true)
    drawFrame(ctx, t: t)
    if let img = ctx.makeImage() { CGImageDestinationAddImage(dest, img, frameProps as CFDictionary) }
}
print(CGImageDestinationFinalize(dest) ? "wrote \(outURL.path) (\(frameCount) frames)" : "finalize failed")
