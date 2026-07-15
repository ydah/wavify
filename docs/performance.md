# Performance

Wavify favors correctness and portable Ruby first. Use streaming for large files:

```ruby
Wavify::Audio.stream("input.wav", chunk_size: 8192)
             .pipe(->(chunk) { chunk })
             .write_to("output.wav")
```

Benchmark tasks:

```bash
bundle exec rake bench:wav_io
bundle exec rake bench:dsp
bundle exec rake bench:flac
bundle exec rake bench:stream
bundle exec rake bench:all
bundle exec rake bench:baseline
bundle exec rake bench:compare
```

Current optimization priorities:

- Use `SampleBuffer#frame_view` when frame iteration is needed without materializing every frame upfront.
- Use `SampleBuffer.new(samples, format, storage: :packed)` when a large immutable buffer should remain compact until random sample access is needed. Sequential `each` does not materialize the full Array.
- `SampleBuffer#hash` fingerprints eight evenly spaced samples in O(1) time. Hash collisions fall back to full O(n) equality, as required by Ruby's hash-key contract.
- Keep immutable public APIs while allowing internal buffer reuse where safe.
- Prefer streaming pipelines for large inputs.
- Keep pure Ruby codecs measurable with stable benchmark scripts.

Set `BENCH_JSON=path/to/report.json` when running an individual benchmark to write a machine-readable report.
Use `bench:baseline` to write reports under `tmp/benchmarks/baseline`, then `bench:compare` to compare a later run with `BENCH_THRESHOLD` (default `1.2`).
The scheduled benchmark workflow runs a short smoke baseline so benchmark scripts stay healthy in CI without making pull requests slow.
