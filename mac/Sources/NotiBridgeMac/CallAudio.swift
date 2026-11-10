import AVFoundation
import NotiBridgeCore

/// 通话声音在 Mac 上播放和采集。
/// 下行：ESP32 送来的 16 位 PCM（mSBC 16 kHz / CVSD 8 kHz）→ 抖动缓冲 → 扬声器。
/// 上行：麦克风 → 系统语音处理（回声消除、降噪、自动增益）→ 转成同样的格式 → 每 7.5 ms 一帧发给 ESP32。
/// 回声消除用 macOS 自带的语音处理（AVAudioEngine 的 voice processing），它以扬声器输出为参考消掉回声。
final class CallAudio {
    let sampleRate: Int
    private let engine = AVAudioEngine()
    private let jitter: JitterBuffer
    private let sendUp: ([UInt8]) -> Void
    private var converter: AVAudioConverter?
    private var pendingUp: [Int16] = []
    private let frameSamples: Int
    private let format: AVAudioFormat
    var onLog: ((String) -> Void)?

    init(sampleRate: Int, sendUp: @escaping ([UInt8]) -> Void) {
        self.sampleRate = sampleRate
        self.sendUp = sendUp
        jitter = JitterBuffer(sampleRate: sampleRate, targetMs: 60, maxMs: 180)
        frameSamples = sampleRate * 75 / 10000 // 7.5 ms
        format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(sampleRate), channels: 1,
                               interleaved: false)!
    }

    /// 收到 ESP32 的下行音频（串口线程）
    private var received = 0, sent = 0
    func receive(_ bytes: [UInt8]) {
        received += 1
        if received == 1 || received % 1000 == 0 { onLog?("通话声音：已收到 \(received) 帧、已发送 \(sent) 帧") }
        jitter.push(PCM16.samples(bytes))
    }

    func start() throws {
        let input = engine.inputNode
        // 打开系统语音处理：回声消除 + 降噪；它会同时作用在输出上，用于取回声参考
        try input.setVoiceProcessingEnabled(true)

        // 下行播放：按播放设备的节奏从抖动缓冲取数据
        let jitter = self.jitter
        let source = AVAudioSourceNode(format: format) { _, _, frameCount, abl -> OSStatus in
            let n = Int(frameCount)
            let s = jitter.pull(n)
            let buffers = UnsafeMutableAudioBufferListPointer(abl)
            for b in buffers {
                guard let p = b.mData?.assumingMemoryBound(to: Float.self) else { continue }
                for i in 0..<n { p[i] = Float(s[i]) / 32768 }
            }
            return noErr
        }
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)

        // 上行采集：转成 sampleRate 单声道，凑够 7.5 ms 发一帧
        let inFormat = input.outputFormat(forBus: 0)
        converter = AVAudioConverter(from: inFormat, to: format)
        input.installTap(onBus: 0, bufferSize: AVAudioFrameCount(inFormat.sampleRate / 100), format: inFormat) {
            [weak self] buffer, _ in
            self?.captured(buffer)
        }
        engine.prepare()
        try engine.start()
        onLog?("通话声音已切到 Mac（\(sampleRate / 1000) kHz，系统回声消除已开启）")
    }

    private func captured(_ buffer: AVAudioPCMBuffer) {
        guard let converter else { return }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let cap = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 32)
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: cap) else { return }
        var given = false
        var err: NSError?
        converter.convert(to: out, error: &err) { _, status in
            if given {
                status.pointee = .noDataNow
                return nil
            }
            given = true
            status.pointee = .haveData
            return buffer
        }
        guard err == nil, let ch = out.floatChannelData?[0] else { return }
        for i in 0..<Int(out.frameLength) {
            let v = max(-1, min(1, ch[i]))
            pendingUp.append(Int16(v * 32767))
        }
        while pendingUp.count >= frameSamples {
            let frame = Array(pendingUp.prefix(frameSamples))
            pendingUp.removeFirst(frameSamples)
            sendUp(PCM16.bytes(frame))
            sent += 1
        }
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        jitter.reset()
        if jitter.underruns > 0 || jitter.dropped > 0 {
            onLog?("通话声音统计：欠载 \(jitter.underruns) 次，丢弃 \(jitter.dropped) 个样本")
        }
    }
}
