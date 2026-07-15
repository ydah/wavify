# Streaming

`Wavify::Audio.stream` creates a lazy chunk pipeline for large files.

```ruby
stream = Wavify::Audio.stream("input.wav", chunk_size: 4096)
stream.pipe(Wavify::Effects::Compressor.new(threshold: -18, ratio: 3.0), name: :bus_compressor)
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

`Stream#pipeline` returns the processor list for inspection, while `Stream#pipeline_steps` includes optional names.

Convenience helpers cover common streaming workflows:

```ruby
peaks = []

preview = Wavify::Audio.stream("input.wav", chunk_size: 2048)
                       .drop_duration(Wavify.seconds(2))
                       .take_duration(Wavify.seconds(10))
                       .map_chunks(name: :half_gain) { |chunk| Wavify::Audio.new(chunk).gain(-6).buffer }
                       .meter { |stats| peaks << stats[:peak_dbfs] }
                       .tee("preview.wav")
                       .to_audio
```

`progress(total_frames:)` reports cumulative processed frames and an optional progress ratio. `tee` writes the processed stream to an additional output as the stream is consumed.
Use `dry_run(format:)` to validate reading, processors, and optional output conversion without writing files. `latency`, `lookahead`, and `pipeline_steps` expose processor timing metadata when processors provide it.
Streaming failures are raised as `StreamError` with codec, target, and `chunk_size` context.

Lookahead processors retain their delay in streamed output. For example, `Limiter#process` emits leading silence equal to `latency`, and `flush` emits the retained final frames. `Stream#write_to` reports this latency but does not remove or shift those samples automatically. Offline `Limiter#apply` returns a latency-compensated result with the original length.

Path-backed streams reopen their source for every pass. Caller-owned IO is rewound before reuse when it supports `rewind`; non-rewindable IO is single-use and raises before a second enumeration. Exceptions from all pipeline processors, including built-in effects and `meter`/`progress` callbacks, retain their original exception class. `StreamError` context is added to codec reads, codec writes, targets, and chunk framing rather than processor internals.
