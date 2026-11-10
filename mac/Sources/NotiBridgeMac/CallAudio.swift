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

    /// 先试系统回声消除；部分声卡组合（例如 USB 声卡只有输出、麦克风在另一个设备上）打不开时，退回普通模式
    func start() throws {
        do {
            try start(voiceProcessing: true)
        } catch {
            onLog?("系统回声消除打不开（\((error as NSError).code)），改用普通模式；建议戴耳机通话以免回声")
            stopEngine()
            try start(voiceProcessing: false)
        }
    }

    private var sourceNode: AVAudioSourceNode?

    private func stopEngine() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        if let n = sourceNode {
            engine.detach(n)
            sourceNode = nil
        }
        engine.reset()
    }

    private func start(voiceProcessing: Bool) throws {
        let input = engine.inputNode
        // 系统语音处理：回声消除 + 降噪；它会同时作用在输出上，用于取回声参考
        if input.isVoiceProcessingEnabled != voiceProcessing { try input.setVoiceProcessingEnabled(voiceProcessing) }

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
        sourceNode = source
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
        if sender == nil { startSender() }
        onLog?("通话声音已切到 Mac（\(sampleRate / 1000) kHz，\(voiceProcessing ? "系统回声消除已开启" : "未使用回声消除")，输入 \(Int(inFormat.sampleRate)) Hz × \(inFormat.channelCount)）")
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
        // 系统一次给的麦克风数据可能有 100 ms，一口气发出去会让 ESP32 的串口接收溢出：
        // 先放进队列，由发送线程每 7.5 ms 发一帧
        sendLock.lock()
        while pendingUp.count >= frameSamples {
            upQueue.append(PCM16.bytes(Array(pendingUp.prefix(frameSamples))))
            pendingUp.removeFirst(frameSamples)
        }
        // 积压超过 200 ms（时钟漂移）就丢掉最旧的
        if upQueue.count > 27 { upQueue.removeFirst(upQueue.count - 27) }
        sendLock.unlock()
    }

    private var upQueue: [[UInt8]] = []
    private let sendLock = NSLock()
    private var sender: Thread?
    private var sending = false

    private func startSender() {
        sending = true
        let t = Thread { [weak self] in
            var next = Date()
            while let self, self.sending {
                self.sendLock.lock()
                let f = self.upQueue.isEmpty ? nil : self.upQueue.removeFirst()
                self.sendLock.unlock()
                if let f {
                    self.sendUp(f)
                    self.sent += 1
                }
                next = next.addingTimeInterval(0.0075)
                let d = next.timeIntervalSinceNow
                if d > 0 { Thread.sleep(forTimeInterval: d) } else if d < -0.1 { next = Date() }
            }
        }
        t.name = "call-audio-up"
        t.qualityOfService = .userInteractive
        sender = t
        t.start()
    }

    func stop() {
        sending = false
        sender = nil
        stopEngine()
        jitter.reset()
        if jitter.underruns > 0 || jitter.dropped > 0 {
            onLog?("通话声音统计：欠载 \(jitter.underruns) 次，丢弃 \(jitter.dropped) 个样本")
        }
    }
}
