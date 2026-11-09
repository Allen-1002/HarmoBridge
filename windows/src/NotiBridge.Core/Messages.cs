using System.Text.Json;
using System.Text.Json.Serialization;

namespace NotiBridge.Core;

internal static class Json
{
    public static readonly JsonSerializerOptions Options = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
        Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
        NumberHandling = JsonNumberHandling.AllowReadingFromString,
    };
}

/// <summary>外层帧（明文 JSON）。字段按类型可选，见 docs/protocol.md。</summary>
public sealed record Envelope
{
    public required string T { get; init; }
    /// <summary>协议版本（v2 起必带 2）。</summary>
    public int? V { get; init; }
    public string? DeviceId { get; init; }
    public string? DeviceName { get; init; }
    public string? MacId { get; init; }
    public string? MacName { get; init; }
    /// <summary>v1.1：电脑平台 "mac" / "windows"，旧版手机忽略。</summary>
    public string? Platform { get; init; }
    public string? Pub { get; init; }
    public string? Nonce { get; init; }
    public string? Box { get; init; }
    public string? Code { get; init; }
    /// <summary>v2 配对确认码（HMAC，Base64）。</summary>
    public string? Confirm { get; init; }

    public string ToJson() => JsonSerializer.Serialize(this, Json.Options);

    public static Envelope? Parse(string text)
    {
        try { return JsonSerializer.Deserialize<Envelope>(text, Json.Options); }
        catch (JsonException) { return null; }
    }
}

/// <summary>认证后加密在 box 里的业务消息。</summary>
public sealed record Inner
{
    public required string Kind { get; init; }
    public required string Sid { get; init; }
    public required int Seq { get; init; }
    /// <summary>v2：电脑→手机消息的电脑侧递增序号（手机据此防重放）。</summary>
    public int? Cseq { get; init; }
    public string? Id { get; init; }
    public string? BundleName { get; init; }
    public string? AppName { get; init; }
    public string? Title { get; init; }
    public string? Text { get; init; }
    public double? Time { get; init; }
    public bool? Test { get; init; }
    public string[]? Ids { get; init; }
    public string? Result { get; init; }
    public string? Code { get; init; }
    // kind = "settings"：两端共有的同步开关
    public bool? Paused { get; init; }
    public bool? BlockSensitive { get; init; }
    public bool? CopyOtp { get; init; }
    public double? UpdatedAt { get; init; }

    public string ToJson() => JsonSerializer.Serialize(this, Json.Options);

    public static Inner? Parse(string text)
    {
        try { return JsonSerializer.Deserialize<Inner>(text, Json.Options); }
        catch (JsonException) { return null; }
    }
}

/// <summary>手机发来的一条通知（已解密、已校验）。</summary>
public sealed record MirroredNotification(string Id, string BundleName, string AppName, string Title, string Text,
    DateTimeOffset Time, bool IsTest);

/// <summary>手机发来的验证码（只有验证码本身，没有短信全文）。</summary>
public sealed record OtpCode(string Id, string BundleName, string AppName, string Code);

/// <summary>两端共有的同步开关。UpdatedAt 为毫秒时间戳，同步时“后改的为准”。</summary>
public sealed record SharedSettings(bool Paused, bool BlockSensitive, bool CopyOtp, double UpdatedAt)
{
    public SharedSettings Merged(SharedSettings remote) => remote.UpdatedAt > UpdatedAt ? remote : this;
}
