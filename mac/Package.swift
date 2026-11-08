// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "HarmoBridgeMac",
    platforms: [.macOS(.v14)],
    targets: [
        // 与 UI 无关的协议、加密、过滤、去重逻辑，可单元测试
        .target(name: "HarmoBridgeCore"),
        // SwiftUI 菜单栏应用
        .executableTarget(name: "HarmoBridgeMac", dependencies: ["HarmoBridgeCore"]),
        .testTarget(name: "HarmoBridgeCoreTests", dependencies: ["HarmoBridgeCore"]),
    ]
)
