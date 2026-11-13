namespace Earshot.Core;

/// <summary>A model file Earshot downloads the first time it needs it. <see cref="Bytes"/> is the exact size served,
/// checked once the download ends so a cut connection never leaves a broken model behind.</summary>
public sealed record ModelFile(string Id, string Label, string FileName, string Url, long Bytes)
{
    public string SizeText => Bytes >= 1_000_000_000 ? $"{Bytes / 1e9:0.0} GB" : $"{Math.Max(1, Bytes / 1_000_000)} MB";
}

public static class ModelCatalog
{
    /// <summary>%LOCALAPPDATA%\Earshot\Models</summary>
    public static string Folder =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Earshot", "Models");

    const string WhisperBase = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/";

    /// <summary>Whisper models in ggml format, best first. large-v3-turbo is the default: near large-v3 quality at a
    /// fraction of the cost.</summary>
    public static readonly IReadOnlyList<ModelFile> Whisper = new[]
    {
        new ModelFile("large-v3-turbo", "Large v3 Turbo", "ggml-large-v3-turbo.bin", WhisperBase + "ggml-large-v3-turbo.bin", 1_624_555_275),
        new ModelFile("large-v3-turbo-q5_0", "Large v3 Turbo (compact)", "ggml-large-v3-turbo-q5_0.bin", WhisperBase + "ggml-large-v3-turbo-q5_0.bin", 574_041_195),
        new ModelFile("small", "Small", "ggml-small.bin", WhisperBase + "ggml-small.bin", 487_601_967),
        new ModelFile("base", "Base", "ggml-base.bin", WhisperBase + "ggml-base.bin", 147_951_465),
    };

    public const string DefaultWhisper = "large-v3-turbo";

    public static ModelFile WhisperModel(string? id) => Whisper.FirstOrDefault(m => m.Id == id) ?? Whisper[0];

    /// <summary>Silero's voice activity model, in the ONNX form sherpa-onnx runs.</summary>
    public static readonly ModelFile VoiceActivity = new("silero-vad", "Silero VAD", "silero_vad.onnx",
        "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad.onnx", 643_854);

    /// <summary>pyannote's speaker segmentation 3.0, exported for sherpa-onnx.</summary>
    public static readonly ModelFile Segmentation = new("pyannote-segmentation", "pyannote segmentation 3.0", "pyannote-segmentation-3-0.onnx",
        "https://huggingface.co/csukuangfj/sherpa-onnx-pyannote-segmentation-3-0/resolve/main/model.onnx", 5_992_913);

    /// <summary>Speaker embeddings (3D-Speaker ERes2Net), which tell one voice from another.</summary>
    public static readonly ModelFile Embedding = new("speaker-embedding", "3D-Speaker ERes2Net", "3dspeaker_speech_eres2net_base_sv_zh-cn_3dspeaker_16k.onnx",
        "https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models/3dspeaker_speech_eres2net_base_sv_zh-cn_3dspeaker_16k.onnx", 39_593_761);

    public static string PathOf(ModelFile model, string? folder = null) => System.IO.Path.Combine(folder ?? Folder, model.FileName);

    /// <summary>On disk and complete.</summary>
    public static bool IsReady(ModelFile model, string? folder = null)
    {
        var file = new FileInfo(PathOf(model, folder));
        return file.Exists && file.Length == model.Bytes;
    }
}
