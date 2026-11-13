using System.Runtime.InteropServices;
using System.Runtime.Intrinsics.X86;
using System.Text;
using Earshot.Core;
using LLama;
using LLama.Common;
using LLama.Native;
using LLama.Sampling;

namespace Earshot.Engines;

/// <summary>A Qwen3 model run by llama.cpp (LLamaSharp) on the CPU, for the summary. Each question gets a fresh context.</summary>
public sealed class LlamaSummaryModel : ISummaryModel, IDisposable
{
    /// <summary>Tokens of context: a block of transcript (see <see cref="BlockWords"/>), the instructions and the answer.</summary>
    public const int ContextTokens = 8192;
    /// <summary>Words per block of transcript: about 4,000 tokens in French, well within the context.</summary>
    public const int BlockWords = 2400;

    readonly LLamaWeights weights;
    readonly ModelParams parameters;

    public string ModelPath { get; }

    /// <summary>Where failures and answers are reported (the command-line check sets it).</summary>
    public static Action<string>? Log { get; set; }

    public LlamaSummaryModel(string modelPath)
    {
        Prepare();
        ModelPath = modelPath;
        parameters = new ModelParams(modelPath)
        {
            ContextSize = ContextTokens,
            GpuLayerCount = 0,
            Threads = Math.Clamp(Environment.ProcessorCount, 1, 8),
        };
        weights = LLamaWeights.LoadFromFile(parameters);
    }

    /// <summary>Qwen's chat format, with an empty thinking block so the model answers straight away.</summary>
    static string Chat(string instructions, string prompt) =>
        $"<|im_start|>system\n{instructions}<|im_end|>\n<|im_start|>user\n{prompt}<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n";

    public string? Ask(string instructions, string prompt, int maxTokens, CancellationToken cancel)
    {
        var executor = new StatelessExecutor(weights, parameters);
        var inference = new InferenceParams
        {
            MaxTokens = maxTokens,
            AntiPrompts = new[] { "<|im_end|>", "<|im_start|>" },
            SamplingPipeline = new DefaultSamplingPipeline { Temperature = 0.2f },
        };
        var answer = new StringBuilder();
        try
        {
            foreach (var piece in executor.InferAsync(Chat(instructions, prompt), inference, cancel).ToBlockingEnumerable(cancel))
                answer.Append(piece);
        }
        catch (OperationCanceledException) { throw; }
        catch (Exception error)
        {
            Log?.Invoke("model: " + error.Message);
            return null;  // too long for the context, or the model failed: this block is skipped
        }
        var text = answer.ToString();
        Log?.Invoke($"model answered {text.Length} characters: {text[..Math.Min(text.Length, 300)].Replace('\n', '|')}");
        foreach (var stop in inference.AntiPrompts) text = text.Replace(stop, "");
        var think = text.IndexOf("</think>", StringComparison.Ordinal);
        if (think >= 0) text = text[(think + "</think>".Length)..];
        return text.Trim();
    }

    public void Dispose() => weights.Dispose();

    [DllImport("kernel32", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool SetDllDirectory(string path);

    static bool prepared;
    static readonly object PrepareGate = new();

    /// <summary>On Windows, llama.cpp comes in one folder per CPU level (runtimes\win-x64\native\avx2…). The one this CPU
    /// can run is picked here, and Windows is told to look in that folder too, so the libraries llama.dll needs next to it
    /// (ggml*.dll) load with it. Elsewhere LLamaSharp finds its library by itself.</summary>
    static void Prepare()
    {
        lock (PrepareGate)
        {
            if (prepared) return;
            prepared = true;
            NativeLibraryConfig.All.WithLogCallback((level, message) =>
            {
                if (message.Contains("librar", StringComparison.OrdinalIgnoreCase) || level == LLamaLogLevel.Error) Log?.Invoke("llama: " + message.TrimEnd());
            });
            if (!OperatingSystem.IsWindows()) return;
            var arm = RuntimeInformation.ProcessArchitecture == Architecture.Arm64;
            var native = Path.Combine(AppContext.BaseDirectory, "runtimes", arm ? "win-arm64" : "win-x64", "native");
            var levels = arm ? new[] { "" } : new[]
            {
                Avx512F.IsSupported ? "avx512" : null, Avx2.IsSupported ? "avx2" : null, Avx.IsSupported ? "avx" : null, "noavx",
            }.OfType<string>().ToArray();
            var folder = levels.Select(l => Path.Combine(native, l)).FirstOrDefault(f => File.Exists(Path.Combine(f, "llama.dll")));
            if (folder == null) { Log?.Invoke("llama: no llama.dll under " + native); return; }
            SetDllDirectory(folder);
            // Dependencies first, so llama.dll finds them already loaded.
            var handles = new Dictionary<string, IntPtr>();
            foreach (var name in new[] { "ggml-base", "ggml-cpu", "ggml", "llama", "mtmd" })
            {
                var path = Path.Combine(folder, name + ".dll");
                if (File.Exists(path) && NativeLibrary.TryLoad(path, out var handle)) handles[name] = handle;
                else Log?.Invoke("llama: could not load " + path);
            }
            try
            {
                NativeLibrary.SetDllImportResolver(typeof(LLamaWeights).Assembly, (name, _, _) =>
                    handles.TryGetValue(Path.GetFileNameWithoutExtension(name).Replace("lib", ""), out var handle) ? handle : IntPtr.Zero);
            }
            catch (InvalidOperationException) { /* LLamaSharp set its own resolver: it finds the libraries itself */ }
            Log?.Invoke("llama: using " + folder);
        }
    }

    static LlamaSummaryModel? cached;
    static readonly object CacheGate = new();

    /// <summary>The last model stays loaded between sessions: loading takes a few seconds.</summary>
    public static LlamaSummaryModel Cached(string modelPath)
    {
        lock (CacheGate)
        {
            if (cached?.ModelPath == modelPath) return cached;
            cached?.Dispose();
            cached = null;
            cached = new LlamaSummaryModel(modelPath);
            return cached;
        }
    }

    /// <summary>Frees the model's memory (several GB for the bigger ones) when it is not needed.</summary>
    public static void Release()
    {
        lock (CacheGate)
        {
            cached?.Dispose();
            cached = null;
        }
    }
}
