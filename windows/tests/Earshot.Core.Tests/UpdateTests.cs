using Earshot.Core;
using Xunit;

namespace Earshot.Core.Tests;

/// <summary>The daily check against GitHub's latest release: only a newer version is offered.</summary>
public sealed class UpdateTests
{
    [Theory]
    [InlineData("0.6.4", "0.6.3", true)]
    [InlineData("0.6.10", "0.6.9", true)]
    [InlineData("1.0", "0.9.9", true)]
    [InlineData("0.6.3", "0.6.3", false)]
    [InlineData("0.7", "0.7.0", false)]
    [InlineData("0.6.2", "0.6.3", false)]
    public void VersionsAreComparedNumberByNumber(string candidate, string current, bool newer) =>
        Assert.Equal(newer, Updates.IsNewer(candidate, current));

    [Theory]
    [InlineData("""{"tag_name": "v0.7.0", "draft": false}""", "0.7.0")]
    [InlineData("""{"tag_name": "0.7.1"}""", "0.7.1")]
    [InlineData("""{"message": "Not Found"}""", null)]
    [InlineData("""{"tag_name": "nightly"}""", null)]
    [InlineData("not json", null)]
    public void TheVersionIsTheReleaseTagWithoutItsV(string json, string? version) =>
        Assert.Equal(version, Updates.VersionFromRelease(json));

    [Fact]
    public void TheCheckIsOnUntilTurnedOff()
    {
        Assert.True(new AppSettings().CheckUpdates);
        Assert.Equal("0.6.3".Split('.').Length, Updates.Current.Split('.').Length);
    }
}
