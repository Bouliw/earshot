using Earshot.Core;

namespace Earshot.Engines;

/// <summary>Fetches a model the first time it is needed, into %LOCALAPPDATA%\Earshot\Models. The file is written under a
/// ".part" name and only takes its real name once complete and of the expected size.</summary>
public static class ModelDownloader
{
    static readonly HttpClient Http = new() { Timeout = Timeout.InfiniteTimeSpan };
    static readonly SemaphoreSlim OneAtATime = new(1, 1);

    static ModelDownloader() => Http.DefaultRequestHeaders.UserAgent.ParseAdd("Earshot-Windows/0.5");

    /// <summary>The model's path once it is on disk. <paramref name="progress"/> gets bytes done and bytes in all.</summary>
    public static async Task<string> EnsureAsync(ModelFile model, Action<long, long>? progress = null, CancellationToken cancel = default, string? folder = null)
    {
        var path = ModelCatalog.PathOf(model, folder);
        if (ModelCatalog.IsReady(model, folder)) return path;
        await OneAtATime.WaitAsync(cancel);
        try
        {
            if (ModelCatalog.IsReady(model, folder)) return path;
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            var part = path + ".part";
            using (var response = await Http.GetAsync(model.Url, HttpCompletionOption.ResponseHeadersRead, cancel))
            {
                response.EnsureSuccessStatusCode();
                var total = response.Content.Headers.ContentLength ?? model.Bytes;
                await using var input = await response.Content.ReadAsStreamAsync(cancel);
                await using var output = new FileStream(part, FileMode.Create, FileAccess.Write, FileShare.None, 1 << 20);
                var buffer = new byte[1 << 20];
                long done = 0;
                var lastReport = DateTime.MinValue;
                int read;
                while ((read = await input.ReadAsync(buffer, cancel)) > 0)
                {
                    await output.WriteAsync(buffer.AsMemory(0, read), cancel);
                    done += read;
                    if (DateTime.UtcNow - lastReport > TimeSpan.FromMilliseconds(250)) { lastReport = DateTime.UtcNow; progress?.Invoke(done, total); }
                }
                progress?.Invoke(done, total);
            }
            var size = new FileInfo(part).Length;
            if (size != model.Bytes)
            {
                File.Delete(part);
                throw new IOException($"{model.FileName}: got {size} bytes, expected {model.Bytes}");
            }
            File.Move(part, path, overwrite: true);
            return path;
        }
        finally { OneAtATime.Release(); }
    }

    public static string Bytes(long done, long total) =>
        total >= 1_000_000_000 ? $"{done / 1e9:0.00} / {total / 1e9:0.00} GB" : $"{done / 1e6:0} / {total / 1e6:0} MB";
}
