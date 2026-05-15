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
```

Current optimization priorities:

- Avoid unnecessary frame array materialization in hot paths.
- Keep immutable public APIs while allowing internal buffer reuse where safe.
- Prefer streaming pipelines for large inputs.
- Keep pure Ruby codecs measurable with stable benchmark scripts.
