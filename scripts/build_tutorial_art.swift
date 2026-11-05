// Builds the tutorial illustrations from real app renders.
// 1. Capture: xcodebuild test -only-testing:CloudChessUITests/CloudChessUITests/testTutorialArtCaptures
//    -resultBundlePath build-marketing/tutorial.xcresult (iPhone simulator, reduced motion).
// 2. Export: xcrun xcresulttool export attachments --path build-marketing/tutorial.xcresult
//    --output-path build-marketing/tutorial-attachments
// 3. Render: swift scripts/build_tutorial_art.swift build-marketing/tutorial-attachments CloudChess/Assets.xcassets
// Each capture has a screenshot plus every square's projected board-plane centre,
// so arrows sit exactly on the rendered squares. No invented board artwork.
import AppKit
import CoreImage

let input = CommandLine.arguments[1], assets = CommandLine.arguments[2]
func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor { NSColor(srgbRed: r/255, green: g/255, blue: b/255, alpha: a) }
let good = rgb(38, 158, 92), bad = rgb(222, 70, 88), ink = rgb(25, 46, 73), gold = rgb(243, 178, 64)

struct Capture {
    let image: CGImage, scale: CGFloat
    let centres: [String: CGPoint], bar: CGRect?, status: [String: String]
    var spacing: CGFloat {
        guard let a = centres["a1"], let b = centres["b1"] else { return 40 }
        return hypot(b.x - a.x, b.y - a.y)
    }
}
// xcresulttool names files by UUID; manifest.json maps them to attachment names.
func captures() -> [String: Capture] {
    struct Entry: Decodable { let exportedFileName: String; let suggestedHumanReadableName: String }
    struct Test: Decodable { let attachments: [Entry] }
    let manifest = try! JSONDecoder().decode([Test].self, from: Data(contentsOf: URL(fileURLWithPath: input + "/manifest.json")))
    var files: [String: String] = [:]
    for entry in manifest.flatMap(\.attachments) {
        // "tutorial-mate-start_0_<uuid>.png" → "tutorial-mate-start"
        let name = entry.suggestedHumanReadableName.components(separatedBy: "_").first!.replacingOccurrences(of: ".png", with: "").replacingOccurrences(of: ".json", with: "")
        files[name] = input + "/" + entry.exportedFileName
    }
    var out: [String: Capture] = [:]
    for (name, path) in files where name.hasPrefix("tutorial-") && !name.hasSuffix("-meta") {
        guard let metaPath = files[name + "-meta"] else { continue }
        let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil)!
        let image = CGImageSourceCreateImageAtIndex(src, 0, nil)!
        let meta = try! JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: metaPath))) as! [String: Any]
        let scale = CGFloat(image.width) / CGFloat(meta["width"] as! Double)
        var centres: [String: CGPoint] = [:]
        for (sq, xy) in meta["centres"] as! [String: [Double]] { centres[sq] = CGPoint(x: xy[0] * scale, y: xy[1] * scale) }
        let bar = (meta["bar"] as? [Double]).map { CGRect(x: $0[0] * scale, y: $0[1] * scale, width: $0[2] * scale, height: $0[3] * scale) }
        var status: [String: String] = [:]
        for part in (meta["status"] as! String).split(separator: ",") {
            let kv = part.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            status[String(kv[0])] = kv.count > 1 ? String(kv[1]) : ""
        }
        out[String(name.dropFirst(9))] = Capture(image: image, scale: scale, centres: centres, bar: bar, status: status)
    }
    return out
}

final class Art {
    let capture: Capture, crop: CGRect, w: Int, h: Int, ctx: CGContext, k: CGFloat
    /// Where the real render sits inside the canvas (a uniform sky buffer surrounds it).
    private(set) var inset = CGPoint.zero
    /// Where the material bar card was moved to, in output pixels.
    private(set) var barCard: CGRect?
    /// Every image: the board with the same sky margin on all sides (the HUD is
    /// hidden in captures), on one fixed portrait canvas (the board spans the screen width, so height takes the slack).
    static let aspect: CGFloat = 0.85
    init(_ capture: Capture, includeBar: Bool = false, width: Int = 960) {
        self.capture = capture
        let xs = capture.centres.values.map(\.x), ys = capture.centres.values.map(\.y), s = capture.spacing
        let margin = 0.7 * s
        // Square centres sit half a square inside the platform; crowns rise about 0.8 squares.
        var r = CGRect(x: xs.min()! - 0.6 * s - margin, y: ys.min()! - 0.85 * s - margin,
                       width: xs.max()! - xs.min()! + 1.2 * s + 2 * margin, height: ys.max()! - ys.min()! + 1.45 * s + 2 * margin)
        let card = includeBar ? capture.bar : nil
        if let card { r.size.height += card.height + 0.25 * s }
        // Grow the shorter side symmetrically to the shared aspect, staying on screen.
        if r.width / r.height < Self.aspect { let grow = r.height * Self.aspect - r.width; r = r.insetBy(dx: -grow / 2, dy: 0) }
        else { let grow = r.width / Self.aspect - r.height; r = r.insetBy(dx: 0, dy: -grow / 2) }
        let bounds = CGRect(x: 0, y: 0, width: capture.image.width, height: capture.image.height)
        // A board wider than the screen allows keeps the full width; the height follows the aspect.
        if r.width > bounds.width { let mid = r.midY; r.size.width = bounds.width; r.size.height = bounds.width / Self.aspect; r.origin.y = mid - r.height / 2 }
        if r.minX < 0 { r.origin.x = 0 }; if r.maxX > bounds.maxX { r.origin.x = bounds.maxX - r.width }
        if r.minY < 0 { r.origin.y = 0 }; if r.maxY > bounds.maxY { r.origin.y = bounds.maxY - r.height }
        r = r.intersection(bounds).integral
        crop = r; w = width; h = Int((CGFloat(width) / Self.aspect).rounded())
        // The render is inset by a fixed buffer; the buffer is the same sky, blurred,
        // and the render's edges feather into it.
        let buffer = CGFloat(width) * 0.075
        k = min((CGFloat(w) - 2 * buffer) / r.width, (CGFloat(h) - 2 * buffer) / r.height)
        let placed = CGRect(x: (CGFloat(w) - r.width * k) / 2, y: (CGFloat(h) - r.height * k) / 2, width: r.width * k, height: r.height * k)
        inset = placed.origin
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.interpolationQuality = .high
        let source = CIImage(cgImage: capture.image.cropping(to: r)!)
        let canvas = CGRect(x: 0, y: 0, width: w, height: h)
        let cover = max(CGFloat(w) / r.width, CGFloat(h) / r.height) * 1.08
        let background = source.transformed(by: CGAffineTransform(scaleX: cover, y: cover))
            .transformed(by: CGAffineTransform(translationX: (CGFloat(w) - r.width * cover) / 2, y: (CGFloat(h) - r.height * cover) / 2))
            .clampedToExtent().applyingGaussianBlur(sigma: 28).cropped(to: canvas)
        let foreground = source.transformed(by: CGAffineTransform(scaleX: k, y: k))
            .transformed(by: CGAffineTransform(translationX: placed.minX, y: CGFloat(h) - placed.maxY))
        let feather = buffer * 0.45
        let mask = CIImage(color: .white).cropped(to: CGRect(x: placed.minX + feather, y: CGFloat(h) - placed.maxY + feather, width: placed.width - 2 * feather, height: placed.height - 2 * feather))
            .composited(over: CIImage(color: .black).cropped(to: canvas)).applyingGaussianBlur(sigma: feather / 2).cropped(to: canvas)
        let blended = foreground.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: background, kCIInputMaskImageKey: mask]).cropped(to: canvas)
        ctx.draw(CIContext().createCGImage(blended, from: canvas, format: .RGBA8, colorSpace: space)!, in: canvas)
        ctx.translateBy(x: 0, y: CGFloat(h)); ctx.scaleBy(x: 1, y: -1) // top-left origin from here on
        // The real bar card sits far below the board on screen; bring it up under the platform.
        if let card, let image = capture.image.cropping(to: card.integral) {
            let size = CGSize(width: card.width * k, height: card.height * k)
            let platformBottom = (ys.max()! + 0.6 * s - r.minY) * k + inset.y
            let placed = CGRect(x: (CGFloat(w) - size.width) / 2, y: platformBottom + 0.25 * s * k, width: size.width, height: size.height)
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: 6), blur: 18, color: NSColor.black.withAlphaComponent(0.18).cgColor)
            ctx.addPath(CGPath(roundedRect: placed, cornerWidth: 18 * capture.scale * k, cornerHeight: 18 * capture.scale * k, transform: nil)); ctx.clip()
            ctx.translateBy(x: placed.minX, y: placed.maxY); ctx.scaleBy(x: 1, y: -1)
            ctx.draw(image, in: CGRect(origin: .zero, size: size))
            ctx.restoreGState()
            barCard = placed
        }
    }
    var unit: CGFloat { capture.spacing * k }
    func point(_ square: String) -> CGPoint { let p = capture.centres[square]!; return CGPoint(x: (p.x - crop.minX) * k + inset.x, y: (p.y - crop.minY) * k + inset.y) }
    func shadowed(_ body: () -> Void) {
        ctx.saveGState(); ctx.setShadow(offset: CGSize(width: 0, height: unit * 0.04), blur: unit * 0.12, color: NSColor.black.withAlphaComponent(0.35).cgColor)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil); body(); ctx.endTransparencyLayer(); ctx.restoreGState()
    }
    /// A straight move arrow from square centre to square centre.
    func arrow(_ from: String, _ to: String, _ color: NSColor) {
        let a = point(from), b = point(to), d = hypot(b.x - a.x, b.y - a.y), ux = (b.x - a.x) / d, uy = (b.y - a.y) / d
        let w = unit * 0.17, head = unit * 0.42, start = CGPoint(x: a.x + ux * unit * 0.12, y: a.y + uy * unit * 0.12), tip = CGPoint(x: b.x - ux * unit * 0.06, y: b.y - uy * unit * 0.06)
        let base = CGPoint(x: tip.x - ux * head, y: tip.y - uy * head)
        let path = CGMutablePath()
        path.move(to: start); path.addLine(to: base)
        let headPath = CGMutablePath()
        headPath.move(to: tip)
        headPath.addLine(to: CGPoint(x: base.x - uy * head * 0.62, y: base.y + ux * head * 0.62))
        headPath.addLine(to: CGPoint(x: base.x + uy * head * 0.62, y: base.y - ux * head * 0.62))
        headPath.closeSubpath()
        shadowed {
            for (c, extra) in [(NSColor.white, unit * 0.09), (color, 0)] {
                ctx.setStrokeColor(c.cgColor); ctx.setFillColor(c.cgColor); ctx.setLineCap(.round); ctx.setLineJoin(.round)
                ctx.setLineWidth(w + extra); ctx.addPath(path); ctx.strokePath()
                ctx.setLineWidth(extra); ctx.addPath(headPath); if extra > 0 { ctx.drawPath(using: .fillStroke) } else { ctx.fillPath() }
            }
        }
    }
    /// The curved, dashed take-back arrow used for undo.
    func undoArrow(_ from: String, _ to: String) {
        let a = point(from), b = point(to), mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        let d = hypot(b.x - a.x, b.y - a.y), nx = -(b.y - a.y) / d, ny = (b.x - a.x) / d
        let control = CGPoint(x: mid.x + nx * d * 0.55, y: mid.y + ny * d * 0.55)
        let path = CGMutablePath(); path.move(to: a); path.addQuadCurve(to: b, control: control)
        let tx = b.x - control.x, ty = b.y - control.y, tl = hypot(tx, ty), ux = tx / tl, uy = ty / tl, head = unit * 0.40
        let headPath = CGMutablePath()
        headPath.move(to: CGPoint(x: b.x + ux * unit * 0.08, y: b.y + uy * unit * 0.08))
        headPath.addLine(to: CGPoint(x: b.x - ux * head - uy * head * 0.6, y: b.y - uy * head + ux * head * 0.6))
        headPath.addLine(to: CGPoint(x: b.x - ux * head + uy * head * 0.6, y: b.y - uy * head - ux * head * 0.6))
        headPath.closeSubpath()
        shadowed {
            ctx.setLineCap(.round)
            ctx.setStrokeColor(NSColor.white.cgColor); ctx.setLineWidth(unit * 0.22); ctx.addPath(path); ctx.strokePath()
            ctx.setStrokeColor(ink.cgColor); ctx.setLineWidth(unit * 0.12); ctx.setLineDash(phase: 0, lengths: [unit * 0.20, unit * 0.16]); ctx.addPath(path); ctx.strokePath()
            ctx.setLineDash(phase: 0, lengths: [])
            ctx.setFillColor(ink.cgColor); ctx.setStrokeColor(NSColor.white.cgColor); ctx.setLineWidth(unit * 0.06); ctx.addPath(headPath); ctx.drawPath(using: .fillStroke)
        }
        badge("arrow.uturn.backward", ink, at: control)
    }
    func ring(_ square: String, _ color: NSColor) {
        let p = point(square), r = unit * 0.46
        shadowed {
            for (c, width) in [(NSColor.white, unit * 0.14), (color, unit * 0.07)] {
                ctx.setStrokeColor(c.cgColor); ctx.setLineWidth(width)
                ctx.strokeEllipse(in: CGRect(x: p.x - r, y: p.y - r * 0.62, width: 2 * r, height: 2 * r * 0.62))
            }
        }
    }
    func badge(_ name: String, _ color: NSColor, at p: CGPoint) {
        let r = unit * 0.34
        shadowed {
            ctx.setFillColor(color.cgColor); ctx.setStrokeColor(NSColor.white.cgColor); ctx.setLineWidth(unit * 0.07)
            ctx.addEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)); ctx.drawPath(using: .fillStroke)
        }
        let base = NSImage(systemSymbolName: name, accessibilityDescription: nil)!.withSymbolConfiguration(.init(pointSize: r * 1.0, weight: .bold))!
        let tinted = NSImage(size: base.size, flipped: false) { rect in base.draw(in: rect); NSColor.white.set(); rect.fill(using: .sourceAtop); return true }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        tinted.draw(in: CGRect(x: p.x - tinted.size.width / 2, y: p.y - tinted.size.height / 2, width: tinted.size.width, height: tinted.size.height), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
    }
    func badge(_ name: String, _ color: NSColor, near square: String, dx: CGFloat = 0.42, dy: CGFloat = -0.55) {
        let p = point(square); badge(name, color, at: CGPoint(x: p.x + unit * dx, y: p.y + unit * dy))
    }
    /// Highlights the bar's starting marker (the bar itself is the real render).
    func markBar() {
        guard let r = barCard else { return }
        shadowed {
            let path = CGPath(roundedRect: r.insetBy(dx: -unit * 0.08, dy: -unit * 0.08), cornerWidth: unit * 0.35, cornerHeight: unit * 0.35, transform: nil)
            ctx.setStrokeColor(good.cgColor); ctx.setLineWidth(unit * 0.08); ctx.addPath(path); ctx.strokePath()
        }
        badge("arrow.up.right", good, at: CGPoint(x: r.maxX - unit * 0.1, y: r.minY - unit * 0.05))
    }
    func save(_ name: String) {
        let folder = URL(fileURLWithPath: assets).appendingPathComponent(name + ".imageset")
        try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let dest = CGImageDestinationCreateWithURL(folder.appendingPathComponent(name + ".png") as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil); CGImageDestinationFinalize(dest)
        let contents = #"{"images":[{"filename":"\#(name).png","idiom":"universal","scale":"3x"}],"info":{"author":"xcode","version":1}}"#
        try! contents.write(to: folder.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
        print("wrote \(name) \(w)x\(h)")
    }
}

let shots = captures()
for required in ["mate-start", "mate-offtrack", "improve-start", "improve-won"] where shots[required] == nil { fatalError("Missing capture \(required)") }
// Mate in 2: the checking rook lift is the first move; the target is the king.
var art = Art(shots["mate-start"]!); art.ring("a5", bad); art.arrow("e2", "e5", good); art.save("tutorial-mate-goal")
// After the quiet slip Re4 (answered by ...a3) no mate exists: a final try costs a heart.
art = Art(shots["mate-offtrack"]!); art.arrow("e4", "e1", bad); art.badge("heart.slash.fill", bad, near: "e1", dx: 0.62, dy: -0.25); art.save("tutorial-mate-hearts")
// Undo takes the slip back so the winning Re5+ is available again.
art = Art(shots["mate-offtrack"]!); art.undoArrow("e4", "e2"); art.save("tutorial-undo")
// Improve in 2: the knight check forks king and rook.
art = Art(shots["improve-start"]!); art.arrow("c2", "b4", good); art.ring("d5", gold); art.ring("a6", gold); art.save("tutorial-improve-goal")
// Rook won: the material bar ends above its starting marker.
art = Art(shots["improve-won"]!, includeBar: true); art.markBar(); art.save("tutorial-improve-bar")
