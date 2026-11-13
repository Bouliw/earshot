using System.Text;
using Earshot.Core;
using LLama;
using LLama.Common;
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
