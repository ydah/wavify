# Streaming

`Wavify::Audio.stream` creates a lazy chunk pipeline for large files.

```ruby
stream = Wavify::Audio.stream("input.wav", chunk_size: 4096)
stream.pipe(Wavify::Effects::Compressor.new(threshold: -18, ratio: 3.0))
stream.write_to("output.flac", codec_options: { block_size_strategy: :fixed, block_size: 2048 })
```

The `chunk_size` value is measured in sample frames, not interleaved samples or bytes.

Processors may implement any of:

- `process(buffer)`
- `call(buffer)`
- `apply(buffer)`

The preferred order is `process`, then `call`, then `apply`. Stateful processors may also implement:

- `reset`
- `flush(format:)`
- `tail_duration`

`Stream#pipeline` returns the processor list for inspection.
