using System.Text.Json;

namespace NotiBridge.Core.Tests;

/// <summary>docs/test-vectors/pairing-v2.json（四端共用）。</summary>
public static class TestVectors
{
    public static JsonElement Load()
    {
        var dir = new DirectoryInfo(AppContext.BaseDirectory);
        while (dir is not null && !File.Exists(Path.Combine(dir.FullName, "docs", "test-vectors", "pairing-v2.json")))
            dir = dir.Parent;
        if (dir is null) throw new FileNotFoundException("docs/test-vectors/pairing-v2.json");
        return JsonDocument.Parse(File.ReadAllText(Path.Combine(dir.FullName, "docs", "test-vectors", "pairing-v2.json"))).RootElement;
    }

    public static byte[] Hex(this JsonElement e, string name) => Convert.FromHexString(e.GetProperty(name).GetString()!);
    public static string Str(this JsonElement e, string name) => e.GetProperty(name).GetString()!;
    public static string ToHex(byte[] b) => Convert.ToHexString(b).ToLowerInvariant();
}
