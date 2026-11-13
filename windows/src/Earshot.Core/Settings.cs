using System.Text.Json;
using System.Text.Json.Serialization;

namespace Earshot.Core;

/// <summary>What the user chose in Settings, kept in %LOCALAPPDATA%\Earshot\settings.json.</summary>
public sealed class AppSettings
{
    [JsonPropertyName("model")] public string Model { get; set; } = ModelCatalog.DefaultWhisper;
    /// <summary>"auto", "en" or "fr".</summary>
    [JsonPropertyName("language")] public string Language { get; set; } = "auto";
    /// <summary>The user's name on the microphone's lines; empty means "Me".</summary>
    [JsonPropertyName("userName")] public string UserName { get; set; } = "";
    [JsonPropertyName("separateVoices")] public bool SeparateVoices { get; set; } = true;
    /// <summary>The microphone's device id; "" for the default microphone, "none" for no microphone.</summary>
    [JsonPropertyName("microphone")] public string Microphone { get; set; } = "";
    /// <summary>Where sessions go; empty means Documents\Earshot\Calls.</summary>
    [JsonPropertyName("sessionsFolder")] public string SessionsFolder { get; set; } = "";
    [JsonPropertyName("toldAboutTray")] public bool ToldAboutTray { get; set; }
    /// <summary>Summary.txt after each transcript: on unless turned off.</summary>
    [JsonPropertyName("summarize")] public bool Summarize { get; set; } = true;
    /// <summary>"small", "medium", "large" or "xlarge" (see ModelCatalog.SummaryModels).</summary>
    [JsonPropertyName("summaryModel")] public string SummaryModel { get; set; } = ModelCatalog.DefaultSummary;

    [JsonIgnore] public string EffectiveUserName => string.IsNullOrWhiteSpace(UserName) ? L.Me : UserName.Trim();
    [JsonIgnore] public string EffectiveSessionsFolder => string.IsNullOrWhiteSpace(SessionsFolder) ? SessionStore.DefaultBase : SessionsFolder;

    public static string DefaultPath =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Earshot", "settings.json");

    public static AppSettings Load(string? path = null)
    {
        try
        {
            var file = path ?? DefaultPath;
            if (File.Exists(file)) return JsonSerializer.Deserialize<AppSettings>(File.ReadAllText(file), Json.Options) ?? new();
        }
        catch (Exception) { /* a damaged file falls back on the defaults */ }
        return new();
    }

    public void Save(string? path = null)
    {
        var file = path ?? DefaultPath;
        Directory.CreateDirectory(Path.GetDirectoryName(file)!);
        File.WriteAllText(file, JsonSerializer.Serialize(this, Json.Options));
    }
}
