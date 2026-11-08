// 生成 HarmoBridge 图标：macOS AppIcon.icns，以及鸿蒙分层图标的前景/背景 PNG。
// 用法：swift make_icon.swift <输出目录>
import AppKit
import CoreGraphics

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let cs = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: cs, components: [CGFloat((hex >> 16) & 0xff) / 255, CGFloat((hex >> 8) & 0xff) / 255,
                                         CGFloat(hex & 0xff) / 255, a])!
}

func context(_ size: Int) -> CGContext {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high
    return ctx
}

func save(_ ctx: CGContext, _ path: String) {
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

/// 背景渐变：深靛蓝 → 青绿
func drawBackground(_ ctx: CGContext, rect: CGRect) {
    let g = CGGradient(colorsSpace: cs, colors: [color(0x3949AB), color(0x1E88E5), color(0x00BFA5)] as CFArray,
                       locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(g, start: CGPoint(x: rect.minX, y: rect.maxY), end: CGPoint(x: rect.maxX, y: rect.minY),
                           options: [])
    // 顶部柔光
    let glow = CGGradient(colorsSpace: cs, colors: [color(0xFFFFFF, 0.22), color(0xFFFFFF, 0)] as CFArray,
                          locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: rect.midX, y: rect.maxY), startRadius: 0,
                           endCenter: CGPoint(x: rect.midX, y: rect.maxY), endRadius: rect.width * 0.75, options: [])
}

/// 图形：左手机、右电脑，中间一道桥形弧线，右上角橙色通知点。unit = 图形区域边长
func drawGlyph(_ ctx: CGContext, center c: CGPoint, unit u: CGFloat) {
    let white = color(0xFFFFFF)
    ctx.setShadow(offset: CGSize(width: 0, height: -u * 0.02), blur: u * 0.05, color: color(0x000000, 0.25))

    // 手机
    let phone = CGRect(x: c.x - u * 0.46, y: c.y - u * 0.26, width: u * 0.22, height: u * 0.40)
    ctx.setStrokeColor(white)
    ctx.setLineWidth(u * 0.045)
    ctx.addPath(CGPath(roundedRect: phone, cornerWidth: u * 0.05, cornerHeight: u * 0.05, transform: nil))
    ctx.strokePath()
    ctx.setFillColor(white)
    ctx.fill(CGRect(x: phone.midX - u * 0.035, y: phone.minY + u * 0.04, width: u * 0.07, height: u * 0.02))

    // 电脑（屏幕 + 底座）
    let screen = CGRect(x: c.x + u * 0.16, y: c.y - u * 0.12, width: u * 0.32, height: u * 0.24)
    ctx.addPath(CGPath(roundedRect: screen, cornerWidth: u * 0.035, cornerHeight: u * 0.035, transform: nil))
    ctx.strokePath()
    ctx.addPath(CGPath(roundedRect: CGRect(x: screen.minX - u * 0.04, y: screen.minY - u * 0.075,
                                           width: screen.width + u * 0.08, height: u * 0.04),
                       cornerWidth: u * 0.02, cornerHeight: u * 0.02, transform: nil))
    ctx.fillPath()

    // 桥形弧线（虚线，表示通知从手机流向电脑）
    ctx.setLineCap(.round)
    ctx.setLineWidth(u * 0.04)
    ctx.setLineDash(phase: 0, lengths: [u * 0.001, u * 0.07])
    let start = CGPoint(x: phone.maxX + u * 0.10, y: phone.maxY + u * 0.02)
    let end = CGPoint(x: screen.minX - u * 0.03, y: screen.maxY - u * 0.02)
    ctx.move(to: start)
    ctx.addQuadCurve(to: end, control: CGPoint(x: (start.x + end.x) / 2, y: c.y + u * 0.36))
    ctx.strokePath()
    ctx.setLineDash(phase: 0, lengths: [])

    // 手机右上角的通知角标
    ctx.setShadow(offset: .zero, blur: 0, color: nil)
    let dotR = u * 0.06
    let dot = CGRect(x: phone.maxX - dotR * 0.9, y: phone.maxY - dotR * 1.1, width: dotR * 2, height: dotR * 2)
    ctx.setFillColor(color(0xFF7043))
    ctx.fillEllipse(in: dot)
    ctx.setStrokeColor(white)
    ctx.setLineWidth(u * 0.022)
    ctx.strokeEllipse(in: dot)
}

// ---- macOS 图标：1024 画布，圆角矩形 824，留白与系统图标一致
func macIcon(_ size: Int) -> CGContext {
    let ctx = context(size)
    let s = CGFloat(size)
    let body = CGRect(x: s * 100 / 1024, y: s * 100 / 1024, width: s * 824 / 1024, height: s * 824 / 1024)
    let path = CGPath(roundedRect: body, cornerWidth: s * 185 / 1024, cornerHeight: s * 185 / 1024, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 10 / 1024), blur: s * 20 / 1024, color: color(0x000000, 0.3))
    ctx.addPath(path)
    ctx.setFillColor(color(0x1E88E5))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    drawBackground(ctx, rect: body)
    drawGlyph(ctx, center: CGPoint(x: body.midX, y: body.midY), unit: body.width * 0.82)
    ctx.restoreGState()
    return ctx
}

let iconset = "\(out)/AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)
for (base, scales) in [(16, [1, 2]), (32, [1, 2]), (128, [1, 2]), (256, [1, 2]), (512, [1, 2])] {
    for sc in scales {
        let name = sc == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        save(macIcon(base * sc), "\(iconset)/\(name)")
    }
}
save(macIcon(1024), "\(out)/AppIcon-1024.png")

// ---- 鸿蒙分层图标（1024×1024）：背景满铺渐变，前景为透明底图形（安全区内）
let bg = context(1024)
drawBackground(bg, rect: CGRect(x: 0, y: 0, width: 1024, height: 1024))
save(bg, "\(out)/harmony_background.png")
let fg = context(1024)
drawGlyph(fg, center: CGPoint(x: 512, y: 512), unit: 1024 * 0.62)
save(fg, "\(out)/harmony_foreground.png")
print("done")
