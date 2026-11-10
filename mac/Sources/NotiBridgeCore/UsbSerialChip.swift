import Foundation

/// 常见 ESP32 开发板上的 USB 转串口芯片（按 USB VID/PID 识别）。与 Windows 端 UsbSerialChip.cs 一致。
public enum UsbSerialChip {
    public static func name(vendorId: Int?, productId: Int?) -> String? {
        // 只认串口芯片的 PID：同一厂商还有 USB 集线器等其他芯片（例如沁恒的 1a86:8091），不能当成缺驱动
        switch (vendorId, productId) {
        case (0x10C4, 0xEA60?), (0x10C4, 0xEA63?), (0x10C4, 0xEA70?), (0x10C4, 0xEA71?): return "CP210x"
        case (0x1A86, 0x55D4?): return "CH9102"
        case (0x1A86, 0x55D2?), (0x1A86, 0x55D3?), (0x1A86, 0x55D5?), (0x1A86, 0x55D6?), (0x1A86, 0x55D8?): return "CH343"
        case (0x1A86, 0x7522?), (0x1A86, 0x7523?), (0x1A86, 0x5523?), (0x1A86, 0x7584?): return "CH340"
        case (0x0403, 0x6001?), (0x0403, 0x6010?), (0x0403, 0x6011?), (0x0403, 0x6014?), (0x0403, 0x6015?): return "FTDI"
        case (0x303A, _): return "ESP32 原生 USB"
        default: return nil
        }
    }

    /// 插着 USB 串口芯片却没有出现串口：系统里没有这块芯片的驱动。不给下载链接，芯片可能识别不准。
    public static func driverMissingMessage(chips: [String]) -> String {
        let names = Array(Set(chips)).sorted().joined(separator: "、")
        return "检测到 USB 串口芯片（\(names)），但系统里没有它的驱动，所以没有出现串口。请先自行安装这块芯片的驱动，装好后重新插拔板子。"
    }

    public static let notFoundMessage = "没有找到。请用支持数据传输的 USB 线连接 ESP32；如果板子已经插好，可能需要先安装它的 USB 串口芯片驱动。"
}
