using System.Globalization;

namespace Earshot.Core;

/// <summary>Interface text in English and French, following the language of Windows.</summary>
public static class L
{
    static bool french = CultureInfo.CurrentUICulture.TwoLetterISOLanguageName == "fr";

    /// <summary>Picks the language ("en", "fr"); anything else is English.</summary>
    public static void Use(string language) => french = language == "fr";
    public static bool IsFrench => french;

    static string T(string en, string fr) => french ? fr : en;

    public static string AppName => "Earshot";
    public static string Tagline => T("On-device transcription of your calls and classes", "Transcription locale de vos appels et de vos cours");
    public static string Record => T("Record", "Enregistrer");
    public static string Stop => T("Stop", "Arrêter");
    public static string TitlePlaceholder => T("Session title (optional)", "Titre de la session (facultatif)");
    public static string DefaultTitle(DateTime local) => T("Call ", "Appel ") + local.ToString("yyyy-MM-dd HH'h'mm", CultureInfo.InvariantCulture);
    public static string Microphone => T("Microphone", "Micro");
    public static string NoMicrophone => T("No microphone", "Pas de micro");
    public static string DefaultMicrophone => T("Default microphone", "Micro par défaut");
    public static string PcSound => T("PC sound", "Son du PC");
    public static string RecordHint => T(
        "Records the PC's sound and your microphone on two tracks. The transcript is written on this PC once you stop.",
        "Enregistre le son du PC et votre micro sur deux pistes. La transcription est faite sur ce PC une fois l'enregistrement arrêté.");
    public static string Recording => T("Recording", "Enregistrement");
    public static string Sessions => T("Sessions", "Sessions");
    public static string NoSessions => T(
        "No sessions yet. Click Record when the call starts: the transcript is written once you stop.",
        "Aucune session pour l'instant. Cliquez sur Enregistrer au début de l'appel : la transcription est faite à l'arrêt.");
    public static string NoSelection => T("Pick a session to read its transcript.", "Choisissez une session pour lire sa transcription.");
    public static string Waiting => T("Waiting to be transcribed", "En attente de transcription");
    public static string WaitingForRecording => T("Waits for the recording to end", "Attend la fin de l'enregistrement");
    public static string Transcribing(int percent) => T($"Transcribing… {percent}%", $"Transcription… {percent} %");
    public static string TellingVoicesApart => T("Telling voices apart…", "Séparation des voix…");
    public static string Failed(string why) => T($"Transcription failed: {why}", $"La transcription a échoué : {why}");
    public static string Downloading(string name, string progress) => T($"Downloading {name}… {progress}", $"Téléchargement de {name}… {progress}");
    public static string DownloadFailed(string name, string why) => T($"Could not download {name}: {why}", $"Impossible de télécharger {name} : {why}");
    public static string NothingSaid => T("Nothing was said in this session.", "Rien n'a été dit pendant cette session.");
    public static string Settings => T("Settings", "Réglages");
    public static string WhisperModel => T("Whisper model", "Modèle Whisper");
    public static string ModelHint => T(
        "Downloaded once, the first time it is needed. Lighter models are faster on small PCs, at some cost in accuracy.",
        "Téléchargé une seule fois, la première fois qu'il sert. Les modèles plus légers vont plus vite sur les petits PC, avec un peu moins de précision.");
    public static string Downloaded => T("downloaded", "téléchargé");
    public static string ToDownload(string size) => T($"{size} to download", $"{size} à télécharger");
    public static string Language => T("Language spoken", "Langue parlée");
    public static string Detect => T("Detect, for each sentence", "Détecter, phrase par phrase");
    public static string English => T("English", "Anglais");
    public static string French => T("French", "Français");
    public static string YourName => T("Your name in transcripts", "Votre nom dans les transcriptions");
    public static string Me => T("Me", "Moi");
    public static string SeparateVoices => T("Tell voices apart on the other side", "Distinguer les voix de l'autre côté");
    public static string SeparateVoicesHint => T(
        "Speaker models (about 46 MB) are downloaded the first time.",
        "Les modèles des voix (environ 46 Mo) sont téléchargés la première fois.");
    public static string SessionsFolder => T("Sessions folder", "Dossier des sessions");
    public static string OpenFolder => T("Open folder", "Ouvrir le dossier");
    public static string Choose => T("Choose…", "Choisir…");
    public static string Speaker(int n) => T($"Speaker {n}", $"Intervenant {n}");
    public static string RenameSpeaker => T("Rename speaker", "Renommer l'intervenant");
    public static string RenameHint => T(
        "Every line of this speaker takes the new name. Give two speakers the same name to merge them.",
        "Toutes les lignes de cet intervenant prennent le nouveau nom. Donnez le même nom à deux intervenants pour les fusionner.");
    public static string ClickToRename => T("Click a name to rename that speaker.", "Cliquez sur un nom pour renommer l'intervenant.");
    public static string Ok => "OK";
    public static string Cancel => T("Cancel", "Annuler");
    public static string Save => T("Save", "Enregistrer");
    public static string OpenEarshot => T("Open Earshot", "Ouvrir Earshot");
    public static string StartRecording => T("Start recording", "Démarrer l'enregistrement");
    public static string StopRecording => T("Stop recording", "Arrêter l'enregistrement");
    public static string Quit => T("Quit", "Quitter");
    public static string KeepsRunning => T(
        "Earshot keeps running in the notification area. Right-click its icon to quit.",
        "Earshot reste ouvert dans la zone de notification. Clic droit sur son icône pour quitter.");
    public static string QuitWhileBusy => T(
        "A recording or a transcript is in progress. Quit anyway? The recording is kept and transcribed at the next launch.",
        "Un enregistrement ou une transcription est en cours. Quitter quand même ? L'enregistrement est conservé et transcrit au prochain lancement.");
    public static string TranscribeAgain => T("Transcribe again", "Retranscrire");
    public static string Done(string title) => T($"Transcript ready: {title}", $"Transcription prête : {title}");
    public static string NoAudioDevice => T("No sound output found on this PC.", "Aucune sortie son trouvée sur ce PC.");
    public static string Minutes(double seconds)
    {
        var m = (int)(seconds / 60);
        return m >= 60 ? $"{m / 60} h {m % 60:00} min" : $"{Math.Max(m, 1)} min";
    }
}
