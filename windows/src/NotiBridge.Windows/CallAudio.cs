using NAudio.CoreAudioApi;
using NAudio.Wave;
using NotiBridge.Core;

namespace NotiBridge.Windows;

/// <summary>
/// 通话声音在 Windows 上播放和采集，与 Mac 端 CallAudio.swift 对应。
/// 下行：ESP32 的 16 位 PCM（mSBC 16 kHz / CVSD 8 kHz）→ 抖动缓冲 → 默认“通信”播放设备。
/// 上行：默认“通信”录音设备 → 单声道、重采样到 sampleRate → 每 7.5 ms 一帧匀速发给 ESP32。
/// 使用“通信”角色的设备：Windows 会对它启用通信信号处理（支持的声卡/耳机上包括回声消除）。
/// </summary>
internal sealed class CallAudio : IDisposable
{
    public int SampleRate { get; }
    public bool Muted { get; set; }
    private readonly JitterBuffer _jitter;
    private readonly Action<byte[]> _sendUp;
    private readonly Action<string> _log;
    private readonly int _frameSamples;
    private WasapiOut? _out;
    private WasapiCapture? _in;
    private readonly Queue<byte[]> _upQueue = new();
    private readonly object _upLock = new();
    private readonly List<short> _pending = [];
    private Thread? _sender;
    private volatile bool _sending;
    private double _resamplePos;
    private int _received, _sent;

    public CallAudio(int sampleRate, Action<byte[]> sendUp, Action<string> log)
    {
        SampleRate = sampleRate;
        _sendUp = sendUp;
        _log = log;
        _jitter = new JitterBuffer(sampleRate, 60, 180);
        _frameSamples = sampleRate * 75 / 10000;
    }

    /// <summary>收到 ESP32 的下行音频（串口线程）</summary>
    public void Receive(byte[] pcm)
    {
        _received++;
        if (_received == 1 || _received % 1000 == 0) _log($"通话声音：已收到 {_received} 帧、已发送 {_sent} 帧");
        _jitter.Push(Pcm16.Samples(pcm));
    }

    public void Start()
    {
        var en = new MMDeviceEnumerator();
        var outDev = en.GetDefaultAudioEndpoint(DataFlow.Render, Role.Communications);
        var inDev = en.GetDefaultAudioEndpoint(DataFlow.Capture, Role.Communications);
        _out = new WasapiOut(outDev, AudioClientShareMode.Shared, true, 60);
        _out.Init(new JitterProvider(_jitter, SampleRate));
        _out.Play();
        _in = new WasapiCapture(inDev, true, 20);
        _in.DataAvailable += OnCaptured;
        _in.StartRecording();
        _sending = true;
        _sender = new Thread(SendLoop) { IsBackground = true, Name = "call-audio-up", Priority = ThreadPriority.AboveNormal };
        _sender.Start();
        _log($"通话声音已切到电脑（{SampleRate / 1000} kHz，播放：{outDev.FriendlyName}，录音：{inDev.FriendlyName}）");
    }

    private void OnCaptured(object? sender, WaveInEventArgs e)
    {
        if (_in is null) return;
        var f = _in.WaveFormat;
        int ch = f.Channels;
        int bytesPer = f.BitsPerSample / 8;
        int frames = e.BytesRecorded / (bytesPer * ch);
        // 转单声道浮点
        var mono = new float[frames];
        for (int i = 0; i < frames; i++)
        {
            float sum = 0;
            for (int c = 0; c < ch; c++)
            {
                int off = (i * ch + c) * bytesPer;
                sum += f.Encoding == WaveFormatEncoding.IeeeFloat || (f.Encoding == WaveFormatEncoding.Extensible && bytesPer == 4)
                    ? BitConverter.ToSingle(e.Buffer, off)
                    : bytesPer == 2 ? BitConverter.ToInt16(e.Buffer, off) / 32768f : BitConverter.ToInt32(e.Buffer, off) / 2147483648f;
            }
            mono[i] = sum / ch;
        }
        // 降采样：先做简单低通（按比例取平均），再线性插值
        double ratio = (double)f.SampleRate / SampleRate;
        lock (_upLock)
        {
            while (_resamplePos < frames)
            {
                int i0 = (int)_resamplePos;
                int span = Math.Max(1, (int)ratio);
                float acc = 0;
                int n = 0;
                for (int k = 0; k < span && i0 + k < frames; k++) { acc += mono[i0 + k]; n++; }
                float v = Muted ? 0 : Math.Clamp(acc / Math.Max(1, n), -1f, 1f);
                _pending.Add((short)(v * 32767));
                _resamplePos += ratio;
            }
            _resamplePos -= frames;
            while (_pending.Count >= _frameSamples)
            {
                _upQueue.Enqueue(Pcm16.Bytes(_pending.GetRange(0, _frameSamples).ToArray()));
                _pending.RemoveRange(0, _frameSamples);
            }
            while (_upQueue.Count > 27) _upQueue.Dequeue(); // 积压超过 200 ms 就丢最旧的
        }
    }

    /// <summary>系统一次给的录音数据可能有几十毫秒，匀速每 7.5 ms 发一帧，避免 ESP32 串口接收溢出</summary>
    private void SendLoop()
    {
        var sw = System.Diagnostics.Stopwatch.StartNew();
        double next = 0;
        while (_sending)
        {
            byte[]? f = null;
            lock (_upLock) if (_upQueue.Count > 0) f = _upQueue.Dequeue();
            if (f is not null) { _sendUp(f); _sent++; }
            next += 7.5;
            var wait = next - sw.Elapsed.TotalMilliseconds;
            if (wait > 0) Thread.Sleep(TimeSpan.FromMilliseconds(wait));
            else if (wait < -100) next = sw.Elapsed.TotalMilliseconds;
        }
    }

    public void Dispose()
    {
        _sending = false;
        try { _in?.StopRecording(); } catch (Exception) { }
        _in?.Dispose();
        try { _out?.Stop(); } catch (Exception) { }
        _out?.Dispose();
        _in = null;
        _out = null;
        if (_jitter.Underruns > 0 || _jitter.Dropped > 0) _log($"通话声音统计：欠载 {_jitter.Underruns} 次，丢弃 {_jitter.Dropped} 个样本");
        _jitter.Reset();
    }

    /// <summary>按播放设备的节奏从抖动缓冲取 16 位单声道 PCM</summary>
    private sealed class JitterProvider(JitterBuffer jitter, int sampleRate) : IWaveProvider
    {
        public WaveFormat WaveFormat { get; } = new(sampleRate, 16, 1);

        public int Read(byte[] buffer, int offset, int count)
        {
            var s = new short[count / 2];
            jitter.Pull(s);
            Buffer.BlockCopy(s, 0, buffer, offset, s.Length * 2);
            return s.Length * 2;
        }
    }
}
