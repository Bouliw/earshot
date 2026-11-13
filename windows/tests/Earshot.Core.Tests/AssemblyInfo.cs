using Xunit;

// The interface language is process-wide: tests that switch it must not run at the same time.
[assembly: CollectionBehavior(DisableTestParallelization = true)]
