import AppKit
import Combine
import SwiftUI

@main
struct HarmoBridgeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // 菜单栏图标、弹窗和主窗口都由 AppDelegate 用 AppKit 管理：
        // SwiftUI 的 MenuBarExtra 在菜单栏应用里打开窗口时经常要点两次，弹窗第一次点击也只会激活窗口。
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let model = AppModel()

    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var mainWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()
    private var currentSymbol = ""

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = "HarmoBridge"
        }
        updateStatusIcon()
        model.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateStatusIcon() }
            .store(in: &cancellables)

        let menu = NSHostingController(
            rootView: StatusMenu(openMain: { [weak self] in self?.showMainWindow() })
                .environmentObject(model))
        menu.sizingOptions = .preferredContentSize
        popover.contentViewController = menu
        popover.behavior = .transient
        popover.animates = true

        if !model.onboarded { showMainWindow() }
        // 占位用的空 Settings 场景窗口可能被系统“恢复窗口”带回来，启动时关掉
        closeStraySettingsWindows()
        DispatchQueue.main.async { [weak self] in self?.closeStraySettingsWindows() }
    }

    private func closeStraySettingsWindows() {
        for window in NSApp.windows
        where window !== mainWindow && window.identifier?.rawValue.contains("Settings") == true {
            window.close()
        }
    }

    /// 在访达或启动台再次打开 App 时显示主窗口
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return false
    }

    private func updateStatusIcon() {
        let symbol = model.statusSymbol
        guard symbol != currentSymbol, let button = statusItem?.button else { return }
        currentSymbol = symbol
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "HarmoBridge")
        image?.isTemplate = true
        button.image = image
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
            return
        }
        // 先激活应用，弹窗一出现就是活跃窗口：第一次点击直接生效，材质也不会在点击时从“非活跃”跳成“活跃”
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    func showMainWindow() {
        popover.performClose(nil)
        let window = mainWindow ?? makeMainWindow()
        mainWindow = window
        // 打开主窗口时临时显示程序坞图标，窗口才能可靠地切到最前面，也能用 ⌘Tab 切换
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // 刚切换激活策略的这一轮里窗口可能还在别的应用后面，下一轮再提一次
        DispatchQueue.main.async {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func makeMainWindow() -> NSWindow {
        let host = NSHostingController(rootView: MainWindow().environmentObject(model))
        host.sceneBridgingOptions = .all
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.contentViewController = host
        window.title = "HarmoBridge"
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setContentSize(NSSize(width: 900, height: 640))
        window.center()
        window.setFrameAutosaveName("HarmoBridgeMain")
        return window
    }

    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === mainWindow else { return }
        // 关掉主窗口后回到只有菜单栏图标的状态
        NSApp.setActivationPolicy(.accessory)
    }
}
