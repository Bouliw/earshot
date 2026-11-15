using System;
using System.Diagnostics;
using System.Drawing;
using WinForms = System.Windows.Forms;
using Earshot.Core;

namespace Earshot.Desktop;

/// <summary>The icon in the notification area: open the window, start or stop a recording, quit. Earshot keeps running
/// there when the window is closed, so a transcript can finish in the background.</summary>
sealed class Tray : IDisposable
{
    readonly App app;
    readonly WinForms.NotifyIcon icon;
    readonly WinForms.ToolStripMenuItem openItem;
    readonly WinForms.ToolStripMenuItem recordItem;
    readonly WinForms.ToolStripMenuItem updateItem;
    readonly WinForms.ToolStripMenuItem quitItem;
    /// <summary>The newer version offered in the menu, if any.</summary>
    string? update;
    /// <summary>Where a click on the last notice leads: a web page, or the window when null.</summary>
    string? noticeLink;

    public Tray(App app)
    {
        this.app = app;
        var menu = new WinForms.ContextMenuStrip();
        openItem = new WinForms.ToolStripMenuItem(L.OpenEarshot, null, (_, _) => app.ShowWindow());
        recordItem = new WinForms.ToolStripMenuItem(L.StartRecording, null, (_, _) => app.ToggleRecording());
        updateItem = new WinForms.ToolStripMenuItem("", null, (_, _) => OpenPage(Updates.ReleasesPage)) { Visible = false };
        quitItem = new WinForms.ToolStripMenuItem(L.Quit, null, (_, _) => app.Quit());
        menu.Items.Add(openItem);
        menu.Items.Add(recordItem);
        menu.Items.Add(new WinForms.ToolStripSeparator());
        menu.Items.Add(updateItem);
        menu.Items.Add(quitItem);
        icon = new WinForms.NotifyIcon
        {
            Icon = LoadIcon(),
            Text = "Earshot",
            ContextMenuStrip = menu,
            Visible = true,
        };
        icon.MouseClick += (_, e) => { if (e.Button == WinForms.MouseButtons.Left) app.ShowWindow(); };
        icon.BalloonTipClicked += (_, _) =>
        {
            if (noticeLink != null) OpenPage(noticeLink); else app.ShowWindow();
        };
    }

    static Icon LoadIcon()
    {
        var resource = System.Windows.Application.GetResourceStream(new Uri("pack://application:,,,/Assets/earshot.ico"));
        using var stream = resource!.Stream;
        return new Icon(stream, WinForms.SystemInformation.SmallIconSize);
    }

    static void OpenPage(string url)
    {
        try { Process.Start(new ProcessStartInfo(url) { UseShellExecute = true }); } catch (Exception) { }
    }

    public void Update(bool recording)
    {
        recordItem.Text = recording ? L.StopRecording : L.StartRecording;
        icon.Text = recording ? $"Earshot · {L.Recording}" : "Earshot";
    }

    /// <summary>A newer release to offer in the menu; null takes the item away.</summary>
    public void ShowUpdate(string? version)
    {
        update = version;
        updateItem.Visible = version != null;
        if (version != null) updateItem.Text = L.DownloadVersion(version);
    }

    /// <summary>The menu again, after the app's language changed.</summary>
    public void ApplyTexts(bool recording)
    {
        openItem.Text = L.OpenEarshot;
        quitItem.Text = L.Quit;
        ShowUpdate(update);
        Update(recording);
    }

    /// <summary>A notice above the icon; a click on it opens <paramref name="link"/>, or the window.</summary>
    public void Notify(string text, string? link = null)
    {
        noticeLink = link;
        icon.ShowBalloonTip(5000, "Earshot", text, WinForms.ToolTipIcon.None);
    }

    public void Dispose()
    {
        icon.Visible = false;
        icon.Dispose();
    }
}
