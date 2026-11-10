using System.Text;
using NotiBridge.Core;
using Xunit;

namespace NotiBridge.Core.Tests;

public class AudioLinkTests
{
    [Fact]
    public void DemuxMixesLinesAndFrames()
    {
        var d = new SerialDemux();
        var lines = new List<string>();
        var frames = new List<SerialFrame>();
        var f = SerialDemux.Encode(SerialFrameType.AudioDown, 0x1234, new byte[] { 1, 0xFE, 0x0A, 4 });
        d.Feed(Encoding.UTF8.GetBytes("@{\"t\":\"call\"}\nW (1) log").Concat(f[..3]).ToArray(), lines.Add, frames.Add);
        d.Feed(f[3..].Concat(Encoding.UTF8.GetBytes(" tail\n")).ToArray(), lines.Add, frames.Add);
        Assert.Equal(["@{\"t\":\"call\"}", "W (1) log tail"], lines);
        var fr = Assert.Single(frames);
        Assert.Equal(1, fr.Type);
        Assert.Equal(0x1234, fr.Seq);
        Assert.Equal(new byte[] { 1, 0xFE, 0x0A, 4 }, fr.Data);
    }

    [Fact]
    public void JitterBuffer()
    {
        var j = new JitterBuffer(16000, 10, 30);
        var buf = new short[10];
        j.Pull(buf);
        Assert.All(buf, v => Assert.Equal(0, v));
        j.Push(Enumerable.Repeat((short)7, 200).ToArray());
        j.Pull(buf);
        Assert.All(buf, v => Assert.Equal(7, v));
        j.Push(Enumerable.Repeat((short)8, 1000).ToArray());
        Assert.Equal(160, j.Count);
        j.Pull(new short[200]);
        Assert.Equal(1, j.Underruns);
    }

    [Fact]
    public void PhoneNumbersAndIndex()
    {
        Assert.Equal("13800138000", PhoneNumbers.Key("+86 138-0013-8000"));
        Assert.Equal("10086", PhoneNumbers.Key("10086"));
        var idx = new ContactIndex([new ContactEntry("张三", "+86 138 0013 8000")]);
        Assert.Equal("张三", idx.NameFor("13800138000"));
        Assert.Equal("张三", Assert.Single(idx.Search("0013")).Name);
    }

    [Fact]
    public void ImportVcfAndCsv()
    {
        var vcf = "BEGIN:VCARD\r\nVERSION:3.0\r\nN:三;张;;;\r\nFN:张三\r\nTEL;TYPE=CELL:+86 138 0013 8000\r\nTEL;TYPE=WORK:010-6552\r\n 9988\r\nEND:VCARD\r\n" +
                  "BEGIN:VCARD\r\nVERSION:2.1\r\nN;CHARSET=UTF-8;ENCODING=QUOTED-PRINTABLE:=E6=9D=8E;=E5=9B=9B;;;\r\nTEL;CELL:13900000000\r\nEND:VCARD\r\n";
        var list = ContactImport.ParseVcf(vcf);
        Assert.Equal(3, list.Count);
        Assert.Equal(new ContactEntry("张三", "+86 138 0013 8000"), list[0]);
        Assert.Equal("010-65529988", list[1].Number);
        Assert.Equal("李四", list[2].Name);
        var csv = "姓名,手机,备注\n\"王, 五\",13700000000,同事\n赵六,+86 136 0000 0000,\n";
        var c = ContactImport.ParseCsv(csv);
        Assert.Equal(2, c.Count);
        Assert.Equal("王, 五", c[0].Name);
    }
}
