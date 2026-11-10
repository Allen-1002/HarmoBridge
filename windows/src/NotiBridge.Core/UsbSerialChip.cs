namespace NotiBridge.Core;

/// <summary>常见 ESP32 开发板上的 USB 转串口芯片（按 USB VID/PID 识别）。与 Mac 端 UsbSerialChip.swift 一致。</summary>
public static class UsbSerialChip
{
    /// <summary>只认串口芯片的 PID：同一厂商还有 USB 集线器等其他芯片（例如沁恒的 1a86:8091），不能当成缺驱动。</summary>
    public static string? Name(int? vendorId, int? productId) => (vendorId, productId) switch
    {
        (0x10C4, 0xEA60 or 0xEA63 or 0xEA70 or 0xEA71) => "CP210x",
        (0x1A86, 0x55D4) => "CH9102",
        (0x1A86, 0x55D2 or 0x55D3 or 0x55D5 or 0x55D6 or 0x55D8) => "CH343",
        (0x1A86, 0x7522 or 0x7523 or 0x5523 or 0x7584) => "CH340",
        (0x0403, 0x6001 or 0x6010 or 0x6011 or 0x6014 or 0x6015) => "FTDI",
        (0x303A, _) => "ESP32 原生 USB",
        _ => null,
    };

    /// <summary>插着 USB 串口芯片却没有出现串口：系统里没有这块芯片的驱动。不给下载链接，芯片可能识别不准。</summary>
    public static string DriverMissingMessage(IEnumerable<string> chips) =>
        $"检测到 USB 串口芯片（{string.Join("、", chips.Distinct().Order())}），但系统里没有它的驱动，所以没有出现串口。请先自行安装这块芯片的驱动，装好后重新插拔板子。";

    public const string NotFoundMessage = "没有找到。请用支持数据传输的 USB 线连接 ESP32；如果板子已经插好，可能需要先安装它的 USB 串口芯片驱动。";
}
