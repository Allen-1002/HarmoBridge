import AppKit
import CryptoKit
import Foundation
import NotiBridgeCore

/// 自动更新：从 GitHub Releases 检查新版本，下载 dmg，校验 SHA256 与签名，替换 /Applications 里的 NotiBridge.app 后重新打开。
///
/// 流程：检查 releases/latest → 下载 SHA256SUMS.txt 和 dmg → 校验哈希 → hdiutil 挂载 → 复制出 .app → 卸载
/// → codesign --verify、核对包名和版本 → 写一个小脚本：等本进程退出，替换旧 .app，去掉隔离属性，再打开新版。
@MainActor
final class Updater: ObservableObject {
    static let expectedBundleId = "com.xsh.notibridge.desktop"
    private static let firstCheckDelay: TimeInterval = 30
    private static let checkInterval: TimeInterval = 6 * 3600

    enum Phase: Equatable {
        case idle
        case checking
        case downloading
        case verifying
        case installing
        case failed
    }

    @Published var autoCheck: Bool = UserDefaults.standard.object(forKey: "updateAutoCheck") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(autoCheck, forKey: "updateAutoCheck")
            if autoCheck && !oldValue { scheduleChecks(initialDelay: 5) }
            if !autoCheck { timer?.invalidate(); timer = nil }
        }
    }
    @Published var autoInstall: Bool = UserDefaults.standard.object(forKey: "updateAutoInstall") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoInstall, forKey: "updateAutoInstall") }
    }
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var status = "尚未检查"
    @Published private(set) var progress: Double?
    @Published private(set) var latestVersion: String?
    @Published private(set) var available: UpdateCore.Release?
    @Published private(set) var notes = ""
    @Published private(set) var lastChecked: Date?

    let currentVersion: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"

    /// 返回 false 表示现在不适合更新（例如正在配对手机）
    var canUpdateNow: () -> Bool = { true }
    var onLog: (String) -> Void = { NSLog("NotiBridge: \($0)") }
    var onUpdated: (String) -> Void = { _ in }

    private var timer: Timer?
    private var retryTimer: Timer?
    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.httpAdditionalHeaders = ["User-Agent": UpdateCore.userAgent]
        c.timeoutIntervalForRequest = 30
        c.timeoutIntervalForResource = 30 * 60
        return URLSession(configuration: c)
    }()

    var isBusy: Bool { [.checking, .downloading, .verifying, .installing].contains(phase) }

    // MARK: - 启动

    func start() {
        reportPreviousUpdate()
        cleanupOldWorkDirs()
        if autoCheck { scheduleChecks(initialDelay: Self.firstDelay) }
    }

    private func scheduleChecks(initialDelay: TimeInterval) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: initialDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.autoCheck else { return }
                self.check(manual: false)
                self.timer = Timer.scheduledTimer(withTimeInterval: Self.checkInterval, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self, self.autoCheck else { return }
                        self.check(manual: false)
                    }
                }
            }
        }
    }

    /// 上次更新后重新启动：提示是否成功
    private func reportPreviousUpdate() {
        let d = UserDefaults.standard
        guard let expected = d.string(forKey: "updatePendingVersion") else { return }
        d.removeObject(forKey: "updatePendingVersion")
        if UpdateCore.compareVersions(currentVersion, expected) == 0 {
            log("已更新到 \(currentVersion)")
            status = "已更新到 \(currentVersion)"
            onUpdated(currentVersion)
        } else {
            log("自动更新到 \(expected) 未完成，当前仍是 \(currentVersion)，日志：\(Self.helperLogURL.path)")
            status = "上次更新未完成，可以再试一次"
        }
    }

    // MARK: - 检查

    func check(manual: Bool) {
        guard !isBusy else { return }
        Task { await performCheck(manual: manual) }
    }

    private func performCheck(manual: Bool) async {
        phase = .checking
        status = "正在检查更新…"
        log("检查更新：\(Self.feedURL.absoluteString)（当前 \(currentVersion)）")
        do {
            var req = URLRequest(url: Self.feedURL)
            req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, resp) = try await session.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200 else { throw UpdateError("GitHub 返回 HTTP \(code)") }
            let release = try UpdateCore.decodeRelease(data)
            lastChecked = Date()
            guard !release.draft, !release.prerelease else {
                throw UpdateError("最新 Release 是草稿或预发布版本，已忽略")
            }
            latestVersion = release.version
            notes = release.notesSnippet()
            guard UpdateCore.isNewer(release.version, than: currentVersion) else {
                available = nil
                phase = .idle
                status = "已是最新版本"
                log("已是最新版本（最新 \(release.version)）")
                return
            }
            available = release
            log("发现新版本 \(release.version)")
            if autoInstall {
                await performInstall(release)
            } else {
                phase = .idle
                status = "有新版本 \(release.version)"
            }
        } catch {
            fail("检查更新失败：\(error.localizedDescription)")
        }
    }

    // MARK: - 下载、校验、安装

    /// 用户点“立即更新”
    func installAvailable() {
        guard !isBusy, let r = available else { return }
        Task { await performInstall(r) }
    }

    private func performInstall(_ release: UpdateCore.Release) async {
        guard canUpdateNow() else {
            phase = .idle
            status = "正在配对手机，配对结束后再更新"
            log("正在配对手机，1 分钟后再尝试更新")
            retryTimer?.invalidate()
            retryTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.installAvailable() }
            }
            return
        }
        let version = release.version
        let dmgName = UpdateCore.macAssetName(version: version)
        do {
            guard let dmgAsset = release.asset(named: dmgName) else { throw UpdateError("Release 中没有 \(dmgName)") }
            guard let sumsAsset = release.asset(named: UpdateCore.sumsAssetName) else {
                throw UpdateError("Release 中没有 \(UpdateCore.sumsAssetName)，无法校验，已取消")
            }
            let work = Self.workRoot.appendingPathComponent(version, isDirectory: true)
            try? FileManager.default.removeItem(at: work)
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

            // 1. 校验值
            phase = .downloading
            status = "正在下载校验值…"
            log("下载 \(sumsAsset.browserDownloadURL.absoluteString)")
            let (sumsData, sumsResp) = try await session.data(from: sumsAsset.browserDownloadURL)
            guard (sumsResp as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError("下载校验值失败") }
            let sums = UpdateCore.parseSha256Sums(String(decoding: sumsData, as: UTF8.self))
            guard let expected = sums[dmgName] else { throw UpdateError("SHA256SUMS.txt 中没有 \(dmgName)，已取消") }

            // 2. 安装包
            status = "正在下载 \(version)…"
            progress = 0
            log("下载 \(dmgAsset.browserDownloadURL.absoluteString)（\(dmgAsset.size / 1024) KB）")
            let dmg = work.appendingPathComponent(dmgName)
            try await download(dmgAsset.browserDownloadURL, to: dmg, expectedSize: dmgAsset.size)
            progress = nil

            // 3. 哈希
            phase = .verifying
            status = "正在校验…"
            let actual = try await Self.sha256(of: dmg)
            guard actual == expected else {
                try? FileManager.default.removeItem(at: dmg)
                throw UpdateError("SHA256 不一致（期望 \(expected.prefix(12))…，实际 \(actual.prefix(12))…），已删除下载的文件")
            }
            log("SHA256 校验通过：\(actual)")

            // 4. 挂载并复制出 .app
            let mount = work.appendingPathComponent("mnt", isDirectory: true)
            let staged = work.appendingPathComponent("staged", isDirectory: true)
            try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
            log("挂载 dmg")
            _ = try await Self.run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noautoopen",
                                                        "-mountpoint", mount.path, dmg.path])
            let stagedApp = staged.appendingPathComponent("NotiBridge.app")
            do {
                let src = mount.appendingPathComponent("NotiBridge.app")
                guard FileManager.default.fileExists(atPath: src.path) else { throw UpdateError("dmg 里没有 NotiBridge.app") }
                _ = try await Self.run("/usr/bin/ditto", [src.path, stagedApp.path])
            } catch {
                _ = try? await Self.run("/usr/bin/hdiutil", ["detach", mount.path, "-force"])
                throw error
            }
            _ = try? await Self.run("/usr/bin/hdiutil", ["detach", mount.path])
            log("已复制新版到临时目录")

            // 5. 签名与身份
            _ = try await Self.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", stagedApp.path])
            let info = NSDictionary(contentsOf: stagedApp.appendingPathComponent("Contents/Info.plist"))
            let bid = info?["CFBundleIdentifier"] as? String
            let ver = info?["CFBundleShortVersionString"] as? String
            guard bid == Self.expectedBundleId else { throw UpdateError("新版包名不对（\(bid ?? "无")），已取消") }
            guard let ver, UpdateCore.compareVersions(ver, version) == 0 else {
                throw UpdateError("新版版本号不对（\(ver ?? "无")，期望 \(version)），已取消")
            }
            log("签名校验通过，包名 \(bid ?? "")，版本 \(ver)")

            // 6. 替换并重启
            try install(stagedApp: stagedApp, dmg: dmg, version: version)
        } catch {
            progress = nil
            fail("更新失败：\(error.localizedDescription)")
        }
    }

    private func install(stagedApp: URL, dmg: URL, version: String) throws {
        let target = Bundle.main.bundleURL
        let parent = target.deletingLastPathComponent()
        let fm = FileManager.default
        guard target.pathExtension == "app", !target.path.contains("/AppTranslocation/"),
              fm.isWritableFile(atPath: parent.path), fm.isWritableFile(atPath: target.path) else {
            // 没有写权限（或从 dmg / 隔离目录运行）：交给用户手动拖进“应用程序”
            phase = .idle
            status = "无法自动替换，请手动安装新版"
            log("无法写入 \(target.path)，已在访达中打开新版 dmg")
            NSWorkspace.shared.open(dmg)
            let a = NSAlert()
            a.messageText = "NotiBridge \(version) 已下载并校验通过"
            a.informativeText = "没有权限自动替换 \(target.path)。已打开安装包，请退出 NotiBridge 后把新版拖到“应用程序”文件夹。"
            a.runModal()
            return
        }
        phase = .installing
        status = "正在安装 \(version)，即将重新打开…"
        let script = Self.workRoot.appendingPathComponent("apply-update.sh")
        try Self.helperScript.write(to: script, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = [script.path, String(ProcessInfo.processInfo.processIdentifier), target.path, stagedApp.path,
                       Self.helperLogURL.path]
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        UserDefaults.standard.set(version, forKey: "updatePendingVersion")
        UserDefaults.standard.synchronize()
        log("已启动更新脚本，退出并替换 \(target.path)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
    }

    /// 等旧进程退出 → 备份旧 .app → ditto 新版 → 失败则还原 → 去隔离属性 → 打开
    private static let helperScript = """
    #!/bin/sh
    PID="$1"; TARGET="$2"; NEW="$3"; LOG="$4"
    exec >>"$LOG" 2>&1
    echo "$(date) apply-update pid=$PID target=$TARGET new=$NEW"
    i=0
    while kill -0 "$PID" 2>/dev/null; do
      sleep 0.5; i=$((i+1))
      if [ $i -gt 60 ]; then echo "old process did not exit, killing"; kill -9 "$PID" 2>/dev/null; sleep 1; break; fi
    done
    BACKUP="$TARGET.update-backup"
    rm -rf "$BACKUP"
    if ! mv "$TARGET" "$BACKUP"; then echo "move old app failed"; open "$TARGET"; exit 1; fi
    if /usr/bin/ditto "$NEW" "$TARGET"; then
      rm -rf "$BACKUP"
      echo "replaced"
    else
      echo "ditto failed, restoring"
      rm -rf "$TARGET"; mv "$BACKUP" "$TARGET"
    fi
    /usr/bin/xattr -dr com.apple.quarantine "$TARGET" 2>/dev/null
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$TARGET" 2>/dev/null
    rm -rf "$(dirname "$NEW")"
    open "$TARGET"
    echo "$(date) done"
    """

    // MARK: - 工具

    /// 测试用：环境变量 NOTIBRIDGE_UPDATE_FEED 可指向本地的 Release JSON（只影响从终端直接启动的进程）
    static var feedURL: URL {
        if let s = ProcessInfo.processInfo.environment["NOTIBRIDGE_UPDATE_FEED"], let u = URL(string: s) { return u }
        return UpdateCore.latestReleaseURL
    }

    /// 测试用：NOTIBRIDGE_UPDATE_DELAY 覆盖首次检查的延迟（秒）
    private static var firstDelay: TimeInterval {
        Double(ProcessInfo.processInfo.environment["NOTIBRIDGE_UPDATE_DELAY"] ?? "") ?? firstCheckDelay
    }

    static var workRoot: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("NotiBridgeUpdate", isDirectory: true)
    }

    static var helperLogURL: URL { workRoot.appendingPathComponent("apply-update.log") }

    /// 清理旧版本的下载目录（保留日志）
    private func cleanupOldWorkDirs() {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: Self.workRoot, includingPropertiesForKeys: nil) else { return }
        for u in items where u.lastPathComponent != "apply-update.log" {
            try? fm.removeItem(at: u)
        }
    }

    private func fail(_ message: String) {
        phase = .failed
        status = message
        log(message)
    }

    private func log(_ s: String) { onLog("[更新] \(s)") }

    private func download(_ url: URL, to dest: URL, expectedSize: Int) async throws {
        let delegate = DownloadProgress { [weak self] fraction in
            Task { @MainActor in self?.progress = fraction }
        }
        let (tmp, resp) = try await session.download(from: url, delegate: delegate)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError("下载失败：HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0)") }
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
        let size = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int) ?? -1
        if expectedSize > 0 && size != expectedSize {
            throw UpdateError("下载的文件大小不对（\(size) / \(expectedSize) 字节）")
        }
    }

    nonisolated static func sha256(of url: URL) async throws -> String {
        try await Task.detached {
            let h = try FileHandle(forReadingFrom: url)
            defer { try? h.close() }
            var hasher = SHA256()
            while let chunk = try h.read(upToCount: 1 << 20), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }.value
    }

    @discardableResult
    nonisolated static func run(_ exe: String, _ args: [String]) async throws -> String {
        try await Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: exe)
            p.arguments = args
            let out = Pipe()
            p.standardOutput = out
            p.standardError = out
            p.standardInput = FileHandle.nullDevice
            try p.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let text = String(decoding: data, as: UTF8.self)
            guard p.terminationStatus == 0 else {
                throw UpdateError("\((exe as NSString).lastPathComponent) 失败（\(p.terminationStatus)）：\(text.prefix(300))")
            }
            return text
        }.value
    }
}

struct UpdateError: LocalizedError {
    let message: String
    init(_ m: String) { message = m }
    var errorDescription: String? { message }
}

private final class DownloadProgress: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let onProgress: (Double) -> Void
    private var last = -1.0

    init(_ onProgress: @escaping (Double) -> Void) { self.onProgress = onProgress }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let f = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        if f - last >= 0.01 || f >= 1 {
            last = f
            onProgress(f)
        }
    }

    // async download(from:delegate:) 自己处理文件，这里不需要实现
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}
