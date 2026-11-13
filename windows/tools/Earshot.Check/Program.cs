using Earshot.Engines;

var args2 = args.Contains("--check") || args.Contains("--summarize") ? args : new[] { "--check" }.Concat(args).ToArray();
return await SelfCheck.RunAsync(args2, Console.Out);
