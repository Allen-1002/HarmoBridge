import AppKit
import Foundation
import UserNotifications

/// 为手机通知找一个“原应用图标”，作为 macOS 通知的附件显示在右侧。
/// 优先使用 Mac 上已安装的同名/对应应用的图标，找不到则生成彩色首字母图标。
final class AppIconProvider {
    /// 鸿蒙 / 安卓包名 → Mac 应用包名（常见应用）
    private let knownMap: [String: [String]] = [
        "com.tencent.wechat": ["com.tencent.xinWeChat"],
        "com.tencent.mm": ["com.tencent.xinWeChat"],
        "com.tencent.mqq": ["com.tencent.qq"],
        "com.tencent.hm.qq": ["com.tencent.qq"],
        "com.ss.hm.ugc.aweme": ["com.bytedance.douyin.desktop"],
        "com.alibaba.android.rimet": ["com.alibaba.DingTalkMac"],
        "com.ohos.mms": ["com.apple.MobileSMS"],
        "com.huawei.hmos.email": ["com.apple.mail"],
        "com.ohos.contacts": ["com.apple.iChat", "com.apple.FaceTime"],
        "com.huawei.hmos.calendar": ["com.apple.iCal"],
        "com.bilibili.app.hm": ["com.bilibili.bilibili"],
        // 安卓
        "tv.danmaku.bili": ["com.bilibili.bilibili"],
        "com.ss.android.ugc.aweme": ["com.bytedance.douyin.desktop"],
        "com.google.android.apps.messaging": ["com.apple.MobileSMS"],
        "com.android.mms": ["com.apple.MobileSMS"],
        "com.samsung.android.messaging": ["com.apple.MobileSMS"],
        "com.google.android.gm": ["com.apple.mail"],
        "com.android.email": ["com.apple.mail"],
        "com.google.android.calendar": ["com.apple.iCal"],
        "com.android.calendar": ["com.apple.iCal"],
        "com.google.android.dialer": ["com.apple.FaceTime"],
        "com.android.dialer": ["com.apple.FaceTime"],
        "com.whatsapp": ["net.whatsapp.WhatsApp"],
        "org.telegram.messenger": ["ru.keepcoder.Telegram", "org.telegram.desktop"],
        "com.tencent.wework": ["com.tencent.WeWorkMac"],
        "com.ss.android.lark": ["com.bytedance.lark.Feishu", "com.electron.lark"],
    ]
    private let palette: [NSColor] = [.systemBlue, .systemGreen, .systemOrange, .systemRed, .systemPurple,
                                      .systemTeal, .systemPink, .systemIndigo]
    private var cache: [String: URL] = [:]
    private lazy var installedByName: [String: URL] = Self.scanInstalledApps()
    private let dir: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.xsh.notibridge.mac/icons", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    /// 生成通知附件。系统会把附件文件移走，所以每次复制一份临时文件。
    func attachment(bundleName: String, appName: String) -> UNNotificationAttachment? {
        guard let src = iconFile(bundleName: bundleName, appName: appName) else { return nil }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("hb-icon-\(UUID().uuidString).png")
        do {
            try FileManager.default.copyItem(at: src, to: tmp)
            return try UNNotificationAttachment(identifier: "icon", url: tmp, options: [
                UNNotificationAttachmentOptionsTypeHintKey: "public.png",
            ])
        } catch {
            NSLog("NotiBridge icon attachment failed: \(error.localizedDescription)")
            return nil
        }
    }

    private func iconFile(bundleName: String, appName: String) -> URL? {
        let key = bundleName.isEmpty ? appName : bundleName
        if let u = cache[key], FileManager.default.fileExists(atPath: u.path) { return u }
        let image = macAppIcon(bundleName: bundleName, appName: appName) ?? letterIcon(appName.isEmpty ? key : appName, key: key)
        let url = dir.appendingPathComponent(safe(key) + ".png")
        guard write(image, to: url) else { return nil }
        cache[key] = url
        return url
    }

    private func macAppIcon(bundleName: String, appName: String) -> NSImage? {
        for mac in knownMap[bundleName] ?? [] {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: mac) {
                return NSWorkspace.shared.icon(forFile: url.path)
            }
        }
        // 同名应用（如“微信”“QQ”“钉钉”）
        if let url = installedByName[appName.lowercased()] {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return nil
    }

    private func letterIcon(_ name: String, key: String) -> NSImage {
        let size = NSSize(width: 256, height: 256)
        var h = 0
        for u in key.unicodeScalars { h = (h &* 31 &+ Int(u.value)) % 997 }
        let color = palette[abs(h) % palette.count]
        return NSImage(size: size, flipped: false) { rect in
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: 8, dy: 8), xRadius: 56, yRadius: 56)
            NSGradient(starting: color.blended(withFraction: 0.25, of: .white) ?? color, ending: color)?
                .draw(in: path, angle: -90)
            let letter = String(name.prefix(1)) as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 120, weight: .bold),
                .foregroundColor: NSColor.white,
            ]
            let s = letter.size(withAttributes: attrs)
            letter.draw(at: NSPoint(x: (rect.width - s.width) / 2, y: (rect.height - s.height) / 2), withAttributes: attrs)
            return true
        }
    }

    private func write(_ image: NSImage, to url: URL) -> Bool {
        let target = NSSize(width: 256, height: 256)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 256, pixelsHigh: 256, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return false }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: target))
        NSGraphicsContext.restoreGraphicsState()
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: url)) != nil
    }

    private func safe(_ s: String) -> String {
        s.map { $0.isLetter || $0.isNumber || $0 == "." ? $0 : "_" }.map(String.init).joined()
    }

    /// 扫描 /Applications，建立“显示名 → 路径”索引（含中文本地化名）
    private static func scanInstalledApps() -> [String: URL] {
        var map: [String: URL] = [:]
        let dirs = ["/Applications", "/System/Applications", NSHomeDirectory() + "/Applications"]
        for d in dirs {
            guard let items = try? FileManager.default.contentsOfDirectory(atPath: d) else { continue }
            for item in items where item.hasSuffix(".app") {
                let url = URL(fileURLWithPath: d).appendingPathComponent(item)
                var names: [String] = [String(item.dropLast(4))]
                if let b = Bundle(url: url) {
                    for dict in [b.localizedInfoDictionary, b.infoDictionary] {
                        for k in ["CFBundleDisplayName", "CFBundleName"] {
                            if let n = dict?[k] as? String { names.append(n) }
                        }
                    }
                }
                names.append(FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: ""))
                for n in names where !n.isEmpty {
                    map[n.lowercased()] = map[n.lowercased()] ?? url
                }
            }
        }
        return map
    }
}
