using Earshot.Core;
using Xunit;

namespace Earshot.Core.Tests;

/// <summary>The app's language, picked in Settings: kept between runs and followed by every text.</summary>
public sealed class LanguageTests : IDisposable
{
    readonly string file = Path.Combine(Path.GetTempPath(), "earshot-tests-" + Guid.NewGuid().ToString("N"), "settings.json");

    public void Dispose()
    {
        L.Use("en");
        try { Directory.Delete(Path.GetDirectoryName(file)!, true); } catch (DirectoryNotFoundException) { }
    }

    [Fact]
    public void FollowsWindowsUntilALanguageIsPicked()
    {
        Assert.Equal("system", new AppSettings().InterfaceLanguage);
        Assert.Equal("system", AppSettings.Load(file).InterfaceLanguage);
    }

    [Fact]
    public void ThePickedLanguageIsKept()
    {
        new AppSettings { InterfaceLanguage = "fr" }.Save(file);
        Assert.Equal("fr", AppSettings.Load(file).InterfaceLanguage);
    }

    [Fact]
    public void TextsAndDatesFollowThePickedLanguage()
    {
        L.Use("fr");
        Assert.True(L.IsFrench);
        Assert.Equal("Enregistrer", L.Record);
        Assert.Equal("Langue de l'app", L.AppLanguage);
        Assert.Equal("fr", L.Culture.TwoLetterISOLanguageName);
        Assert.Equal("Moi", new AppSettings().EffectiveUserName);

        L.Use("en");
        Assert.False(L.IsFrench);
        Assert.Equal("Record", L.Record);
        Assert.Equal("en", L.Culture.TwoLetterISOLanguageName);
    }
}
