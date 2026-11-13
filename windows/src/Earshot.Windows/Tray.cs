using System;
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
    readonly WinForms.ToolStripMenuItem quitItem;

    public Tray(App app)
    {
        this.app = app;
        var menu = new WinForms.ContextMenuStrip();
        openItem = new WinForms.ToolStripMenuItem(L.OpenEarshot, null, (_, _) => app.ShowWindow());
        recordItem = new WinForms.ToolStripMenuItem(L.StartRecording, null, (_, _) => app.ToggleRecording());
        quitItem = new WinForms.ToolStripMenuItem(L.Quit, null, (_, _) => app.Quit());
        menu.Items.Add(openItem);
        menu.Items.Add(recordItem);
        menu.Items.Add(new WinForms.ToolStripSeparator());
        menu.Items.Add(quitItem);
        icon = new WinForms.NotifyIcon
        {
            Icon = LoadIcon(),
            Text = "Earshot",
            ContextMenuStrip = menu,
            Visible = true,
        };
        icon.MouseClick += (_, e) => { if (e.Button == WinForms.MouseButtons.Left) app.ShowWindow(); };
        icon.BalloonTipClicked += (_, _) => app.ShowWindow();
    }

    static Icon LoadIcon()
    {
        var resource = System.Windows.Application.GetResourceStream(new Uri("pack://application:,,,/Assets/earshot.ico"));
        using var stream = resource!.Stream;
        return new Icon(stream, WinForms.SystemInformation.SmallIconSize);
    }

    public void Update(bool recording)
    {
        recordItem.Text = recording ? L.StopRecording : L.StartRecording;
        icon.Text = recording ? $"Earshot · {L.Recording}" : "Earshot";
    }

    /// <summary>The menu again, after the app's language changed.</summary>
    public void ApplyTexts(bool recording)
    {
        openItem.Text = L.OpenEarshot;
        quitItem.Text = L.Quit;
        Update(recording);
    }

    public void Notify(string text) => icon.ShowBalloonTip(5000, "Earshot", text, WinForms.ToolTipIcon.None);

    public void Dispose()
    {
        icon.Visible = false;
        icon.Dispose();
    }
}
