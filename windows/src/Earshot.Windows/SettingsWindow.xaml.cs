using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Windows;
using Earshot.Core;
using Microsoft.Win32;

namespace Earshot.Desktop;

public partial class SettingsWindow : Window
{
    sealed record Choice(string Id, string Text);

    readonly AppSettings settings;
    string folder;

    public SettingsWindow(AppSettings settings)
    {
        this.settings = settings;
        folder = settings.EffectiveSessionsFolder;
        InitializeComponent();
        Title = L.Settings;
        Heading.Text = L.Settings;
        ModelLabel.Text = L.WhisperModel;
        ModelHint.Text = L.ModelHint;
        LanguageLabel.Text = L.Language;
        NameLabel.Text = L.YourName;
        VoicesBox.Content = L.SeparateVoices;
        VoicesHint.Text = L.SeparateVoicesHint;
        FolderLabel.Text = L.SessionsFolder;
        ChooseButton.Content = L.Choose;
        OpenButton.Content = L.OpenFolder;
        CancelButton.Content = L.Cancel;
        SaveButton.Content = L.Save;
        var version = Assembly.GetExecutingAssembly().GetName().Version;
        VersionText.Text = $"Earshot for Windows {version?.ToString(3)} · {ModelCatalog.Folder}";

        var models = ModelCatalog.Whisper.Select(m => new Choice(m.Id,
            $"{m.Label} · {(ModelCatalog.IsReady(m) ? L.Downloaded : L.ToDownload(m.SizeText))}")).ToList();
        ModelBox.ItemsSource = models;
        ModelBox.SelectedItem = models.FirstOrDefault(m => m.Id == settings.Model) ?? models[0];

        var languages = new[] { new Choice("auto", L.Detect), new Choice("en", L.English), new Choice("fr", L.French) };
        LanguageBox.ItemsSource = languages;
        LanguageBox.SelectedItem = languages.FirstOrDefault(l => l.Id == settings.Language) ?? languages[0];

        NameBox.Text = settings.EffectiveUserName;
        VoicesBox.IsChecked = settings.SeparateVoices;
        FolderText.Text = folder;
        FolderText.ToolTip = folder;
    }

    void OnChoose(object sender, RoutedEventArgs e)
    {
        var dialog = new OpenFolderDialog { InitialDirectory = Directory.Exists(folder) ? folder : null, Title = L.SessionsFolder };
        if (dialog.ShowDialog(this) != true) return;
        folder = dialog.FolderName;
        FolderText.Text = folder;
        FolderText.ToolTip = folder;
    }

    void OnOpen(object sender, RoutedEventArgs e)
    {
        Directory.CreateDirectory(folder);
        Process.Start(new ProcessStartInfo("explorer.exe", $"\"{folder}\"") { UseShellExecute = true });
    }

    void OnSave(object sender, RoutedEventArgs e)
    {
        settings.Model = (ModelBox.SelectedItem as Choice)?.Id ?? ModelCatalog.DefaultWhisper;
        settings.Language = (LanguageBox.SelectedItem as Choice)?.Id ?? "auto";
        var name = NameBox.Text.Trim();
        settings.UserName = name == L.Me ? "" : name;
        settings.SeparateVoices = VoicesBox.IsChecked == true;
        settings.SessionsFolder = folder == SessionStore.DefaultBase ? "" : folder;
        DialogResult = true;
    }
}
