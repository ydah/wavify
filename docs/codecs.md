# Codecs

Wavify supports WAV, AIFF, FLAC, optional OGG Vorbis, and raw PCM/float.

```ruby
Wavify::Codecs.supported_formats
Wavify::Codecs.available_formats
Wavify::Codecs.detect("input.wav")
Wavify::Audio.metadata("input.wav")
```

Read detection prefers magic bytes when they are available. Use strict mode to catch mismatched extensions:

```ruby
Wavify::Audio.read("renamed.flac", strict: true)
```

Write detection prefers the output extension:

```ruby
audio.write("master.flac")
audio.write("preview.ogg", codec_options: { quality: 0.5 })
audio.write("tagged.wav", codec_options: { info: { title: "Loop", artist: "Wavify" } })
audio.write("little-endian.aifc", codec_options: { compression_type: "sowt" })
audio.write("master.wav", overwrite: false)
```

For IO inputs without container magic bytes, pass a filename hint:

```ruby
io = StringIO.new(raw_bytes)
audio = Wavify::Audio.read(io, filename: "input.raw", format: raw_format)
io.rewind
stream = Wavify::Audio.stream(io, filename: "input.raw", format: raw_format)
```

Codec registration is intentionally small:

```ruby
Wavify::Codecs.register(".custom", MyCodec)
Wavify::Codecs.register(".custom", MyCodec, magic: "CSTM", priority: 10)
Wavify::Codecs.register(".custom", MyCodec, magic: ->(bytes) { bytes.start_with?("CSTM") }, probe_size: 16)
Wavify::Codecs.unregister(".custom")
```

Custom codecs should expose `read`, `write`, `stream_read`, `stream_write`, and `metadata` with the standard positional and `format:` contracts. Magic probes must return `true`, `false`, or `nil`; `probe_size:` is bounded.

External adapter slots are listed without making those dependencies mandatory:

```ruby
Wavify::Adapters.known
Wavify::Adapters.load(:ffmpeg)
```

## Format Notes

- WAV supports PCM and float WAV, including extensible WAV.
- WAV metadata exposes `info:` from LIST/INFO chunks, normalized `loops:` from `smpl`, `cue_points`, Broadcast WAV `bext`, and RF64 `ds64` sizes. Noncanonical `byte_rate` values are tolerated because some encoders write them incorrectly and are reported through `warnings:`. `read` and `stream_read` can also send each warning to an IO-like `warning_io:`; the default `nil` is silent. Invalid `block_align` remains an error because it makes frame boundaries ambiguous.
- AIFF supports PCM AIFF plus uncompressed AIFF-C `NONE` and `sowt` reads and writes. Metadata distinguishes `container_bit_depth:` from `valid_bits_per_sample:` for non-byte-aligned sample sizes and warns when an 80-bit sample rate must be rounded to the integer rate used by `Format`. AIFF `read` and `stream_read` use the same silent-by-default `warning_io:` contract as WAV.
- FLAC is implemented in pure Ruby. Write options include `compression_level:`, `comments:`, `stereo_coding:`, and `predictor:`. LPC mode derives coefficients with autocorrelation and Levinson–Durbin analysis, then searches Rice partition orders per block.
- FLAC metadata and decoding are forward-only and accept readable IO without `seek`; FLAC streaming writes still require seekable output so STREAMINFO can be finalized.
- OGG Vorbis uses optional `ogg-ruby` and `vorbis` gems. Use `Wavify::Codecs.available_formats` or `wavify doctor` to check whether they are installed.
- OGG `stream_read` is incremental for a single logical stream. Chained/interleaved page data is demultiplexed into temporary spools instead of heap-sized Strings; packet decoding, resampling, and mixed output remain chunked.
- Raw PCM/float requires `format:` for read, stream read, and metadata. Use `endianness: :little | :big`, `signed: true | false` for PCM, and `float_domain: :normalized | :ieee` to distinguish clamped audio floats from unrestricted IEEE values.
- `Format` assigns conventional layouts when `channel_layout:` is omitted or `nil`; pass `channel_layout: :unknown` when the speaker positions are explicitly unknown. Extensible WAV preserves this as a zero channel mask.

Magic-byte inspection preserves the position of seekable IO. For a non-rewindable IO, pass `filename:` so the codec can be selected without consuming its prefix; otherwise detection raises before reading the stream.
The `wavify info` command prints warnings collected in codec metadata even though library reads are silent by default.
