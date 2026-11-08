using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Runtime.InteropServices;

namespace HarmoBridge.Windows;

/// <summary>
/// 用 Windows 自带的 DNS-SD（dnsapi.dll DnsServiceRegister，Windows 10 1809+）广播 _harmobridge._tcp，
/// 手机端“自动发现”就能找到这台电脑；与 Mac 端 Bonjour 广播的服务类型和命名一致。
/// 广播失败不影响使用，手机上可以手动输入 IP。
/// </summary>
internal sealed class MdnsAdvertiser : IDisposable
{
    private const uint DnsQueryRequestVersion1 = 1;
    private const uint DnsRequestPending = 9506;

    [UnmanagedFunctionPointer(CallingConvention.Winapi)]
    private delegate void RegisterComplete(uint status, IntPtr context, IntPtr instance);

    [StructLayout(LayoutKind.Sequential)]
    private struct DnsServiceRegisterRequest
    {
        public uint Version;
        public uint InterfaceIndex;
        public IntPtr ServiceInstance;
        public IntPtr RegisterCompletionCallback;
        public IntPtr QueryContext;
        public IntPtr Credentials;
        public int UnicastEnabled;
    }

    [DllImport("dnsapi.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
    private static extern IntPtr DnsServiceConstructInstance(string serviceName, string hostName, IntPtr ip4, IntPtr ip6,
        ushort port, ushort priority, ushort weight, uint propertiesCount,
        [MarshalAs(UnmanagedType.LPArray, ArraySubType = UnmanagedType.LPWStr)] string[] keys,
        [MarshalAs(UnmanagedType.LPArray, ArraySubType = UnmanagedType.LPWStr)] string[] values);

    [DllImport("dnsapi.dll", ExactSpelling = true)]
    private static extern uint DnsServiceRegister(IntPtr request, IntPtr cancel);

    [DllImport("dnsapi.dll", ExactSpelling = true)]
    private static extern uint DnsServiceDeRegister(IntPtr request, IntPtr cancel);

    [DllImport("dnsapi.dll", ExactSpelling = true)]
    private static extern void DnsServiceFreeInstance(IntPtr instance);

    private readonly RegisterComplete _callback;
    private readonly Action<string> _log;
    private IntPtr _instance;
    private IntPtr _request;
    private IntPtr _ip4;
    private string _name = "";
    private string _id = "";
    private int _port;

    public MdnsAdvertiser(Action<string> log)
    {
        _log = log;
        _callback = OnComplete; // 必须持有委托，防止被 GC 回收
        NetworkChange.NetworkAddressChanged += (_, _) =>
        {
            if (_port > 0) Register(_name, _id, _port);
        };
    }

    public void Register(string instanceName, string computerId, int port)
    {
        _name = instanceName;
        _id = computerId;
        _port = port;
        Unregister();
        try
        {
            var ip = PrimaryIPv4();
            if (ip is not null)
            {
                _ip4 = Marshal.AllocHGlobal(4);
                Marshal.WriteInt32(_ip4, BitConverter.ToInt32(ip.GetAddressBytes(), 0));
            }
            var host = Dns.GetHostName() + ".local";
            var service = $"{Sanitize(instanceName)}.{Core.BridgeServer.ServiceType}.local";
            string[] keys = ["id", "platform"];
            string[] values = [computerId, "windows"];
            _instance = DnsServiceConstructInstance(service, host, _ip4, IntPtr.Zero, (ushort)port, 0, 0,
                (uint)keys.Length, keys, values);
            if (_instance == IntPtr.Zero)
            {
                _log("局域网自动发现不可用（无法创建 DNS-SD 实例），手机上可手动输入本机 IP");
                return;
            }
            var req = new DnsServiceRegisterRequest
            {
                Version = DnsQueryRequestVersion1,
                InterfaceIndex = 0,
                ServiceInstance = _instance,
                RegisterCompletionCallback = Marshal.GetFunctionPointerForDelegate(_callback),
            };
            _request = Marshal.AllocHGlobal(Marshal.SizeOf<DnsServiceRegisterRequest>());
            Marshal.StructureToPtr(req, _request, false);
            var r = DnsServiceRegister(_request, IntPtr.Zero);
            if (r != DnsRequestPending)
                _log($"局域网自动发现注册失败（{r}），手机上可手动输入本机 IP");
        }
        catch (Exception e) when (e is DllNotFoundException or EntryPointNotFoundException)
        {
            _log("当前 Windows 版本不支持 DNS-SD 广播（需要 Windows 10 1809+），手机上可手动输入本机 IP");
        }
    }

    private void OnComplete(uint status, IntPtr context, IntPtr instance)
    {
        _log(status == 0 ? $"已在局域网广播 {Core.BridgeServer.ServiceType}" : $"局域网广播失败（{status}）");
        if (instance != IntPtr.Zero) DnsServiceFreeInstance(instance);
    }

    public void Unregister()
    {
        if (_request != IntPtr.Zero)
        {
            try { DnsServiceDeRegister(_request, IntPtr.Zero); }
            catch (Exception) { }
        }
        // 注册请求里的实例在注销完成前仍可能被系统引用，这里不立即释放 _request/_instance，进程退出时由系统回收。
        _request = IntPtr.Zero;
        _instance = IntPtr.Zero;
        _ip4 = IntPtr.Zero;
    }

    public void Dispose()
    {
        _port = 0;
        Unregister();
    }

    /// <summary>有默认网关的物理网卡上的 IPv4，排除虚拟网卡和 VPN。</summary>
    public static IPAddress? PrimaryIPv4() =>
        LanAddresses().Select(a => a.Address).FirstOrDefault();

    public static IReadOnlyList<(IPAddress Address, string Interface)> LanAddresses()
    {
        var list = new List<(IPAddress, string, int)>();
        foreach (var ni in NetworkInterface.GetAllNetworkInterfaces())
        {
            if (ni.OperationalStatus != OperationalStatus.Up) continue;
            if (ni.NetworkInterfaceType is NetworkInterfaceType.Loopback or NetworkInterfaceType.Tunnel) continue;
            var props = ni.GetIPProperties();
            var hasGateway = props.GatewayAddresses.Any(g => g.Address.AddressFamily == AddressFamily.InterNetwork &&
                                                             !g.Address.Equals(IPAddress.Any));
            var desc = (ni.Description + " " + ni.Name).ToLowerInvariant();
            var isVirtual = desc.Contains("virtual") || desc.Contains("hyper-v") || desc.Contains("vmware") ||
                            desc.Contains("vpn") || desc.Contains("wsl") || desc.Contains("loopback");
            foreach (var ua in props.UnicastAddresses)
            {
                if (ua.Address.AddressFamily != AddressFamily.InterNetwork || IPAddress.IsLoopback(ua.Address)) continue;
                if (ua.Address.ToString().StartsWith("169.254.")) continue;
                var score = (hasGateway ? 0 : 10) + (isVirtual ? 5 : 0) +
                            (ni.NetworkInterfaceType == NetworkInterfaceType.Wireless80211 ? 0 : 1);
                list.Add((ua.Address, ni.Name, score));
            }
        }
        return list.OrderBy(x => x.Item3).Select(x => (x.Item1, x.Item2)).ToList();
    }

    private static string Sanitize(string s) => new(s.Select(c => c == '.' ? '-' : c).ToArray());
}
