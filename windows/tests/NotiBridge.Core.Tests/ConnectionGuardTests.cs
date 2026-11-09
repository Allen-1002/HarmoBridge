using NotiBridge.Core;
using Xunit;

namespace NotiBridge.Core.Tests;

public class ConnectionGuardTests
{
    [Fact]
    public void ConnectionCapAndRelease()
    {
        var g = new ConnectionGuard();
        var t = DateTimeOffset.UtcNow;
        for (var i = 0; i < 16; i++) Assert.Equal(ConnectionGuard.Verdict.Allow, g.Admit($"10.0.0.{i}", t));
        Assert.Equal(ConnectionGuard.Verdict.TooManyConnections, g.Admit("10.0.0.99", t));
        g.ConnectionClosed();
        Assert.Equal(ConnectionGuard.Verdict.Allow, g.Admit("10.0.0.99", t));
    }

    [Fact]
    public void PerIpRateWindow()
    {
        var g = new ConnectionGuard();
        var t = DateTimeOffset.UtcNow;
        for (var i = 0; i < 10; i++) { Assert.Equal(ConnectionGuard.Verdict.Allow, g.Admit("1.1.1.1", t)); g.ConnectionClosed(); }
        Assert.Equal(ConnectionGuard.Verdict.RateLimited, g.Admit("1.1.1.1", t.AddSeconds(30)));
        Assert.Equal(ConnectionGuard.Verdict.Allow, g.Admit("2.2.2.2", t.AddSeconds(30)));
        Assert.Equal(ConnectionGuard.Verdict.Allow, g.Admit("1.1.1.1", t.AddSeconds(61)));
    }

    [Fact]
    public void ExponentialLockout()
    {
        var g = new ConnectionGuard();
        var t = DateTimeOffset.UtcNow;
        g.RecordFailure("x", t);
        g.RecordFailure("x", t);
        Assert.Equal(ConnectionGuard.Verdict.Allow, g.Admit("x", t));
        g.ConnectionClosed();
        g.RecordFailure("x", t);
        Assert.Equal(ConnectionGuard.Verdict.LockedOut, g.Admit("x", t.AddSeconds(29)));
        Assert.Equal(ConnectionGuard.Verdict.Allow, g.Admit("x", t.AddSeconds(31)));
        g.ConnectionClosed();
        g.RecordFailure("x", t.AddSeconds(31));
        Assert.Equal(t.AddSeconds(91), g.LockedUntil("x"));
        for (var i = 0; i < 20; i++) g.RecordFailure("x", t);
        Assert.Equal(t.AddHours(1), g.LockedUntil("x"));
        g.RecordSuccess("x");
        Assert.Equal(ConnectionGuard.Verdict.Allow, g.Admit("x", t));
    }

    [Fact]
    public void FrameLimitsAndDeadlines()
    {
        var g = new ConnectionGuard();
        Assert.Equal(16 * 1024, g.MaxFrame(false));
        Assert.Equal(256 * 1024, g.MaxFrame(true));
        Assert.Equal(TimeSpan.FromSeconds(10), g.Deadline(false));
        Assert.Equal(TimeSpan.FromSeconds(90), g.Deadline(true));
    }
}
