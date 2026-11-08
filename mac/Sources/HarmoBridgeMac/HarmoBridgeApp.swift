import SwiftUI

@main
struct HarmoBridgeApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            StatusMenu().environmentObject(model)
        } label: {
            MenuBarLabel().environmentObject(model)
        }
        .menuBarExtraStyle(.window)

        Window("HarmoBridge", id: "main") {
            MainWindow().environmentObject(model)
        }
        .defaultSize(width: 900, height: 640)
    }
}

/// 菜单栏图标。首次启动（未完成引导）时自动打开主窗口进入引导。
struct MenuBarLabel: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: model.statusSymbol)
            .onAppear {
                if !model.onboarded {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
    }
}
