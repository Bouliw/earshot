using System.Windows;
using Earshot.Core;

namespace Earshot.Desktop;

/// <summary>Renames one speaker everywhere in the session; the same name twice merges two speakers.</summary>
public partial class RenameWindow : Window
{
    public string NewName { get; private set; } = "";

    public RenameWindow(string current)
    {
        InitializeComponent();
        Title = L.RenameSpeaker;
        Heading.Text = L.RenameSpeaker;
        Hint.Text = L.RenameHint;
        CancelButton.Content = L.Cancel;
        OkButton.Content = L.Ok;
        NameBox.Text = current;
        Loaded += (_, _) => { NameBox.Focus(); NameBox.SelectAll(); };
    }

    void OnOk(object sender, RoutedEventArgs e)
    {
        NewName = NameBox.Text.Trim();
        DialogResult = true;
    }
}
