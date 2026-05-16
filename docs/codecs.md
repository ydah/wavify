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
```

Custom codecs should expose `read`, `write`, `stream_read`, `stream_write`, and `metadata`.

## Format Notes

- WAV supports PCM and float WAV, including extensible WAV.
- WAV metadata exposes `info:` from LIST/INFO chunks, normalized `loops:` from `smpl`, `cue_points`, Broadcast WAV `bext`, and RF64 `ds64` sizes.
- AIFF supports PCM AIFF plus uncompressed AIFF-C `NONE` and `sowt`.
- FLAC is implemented in pure Ruby. Write options include `compression_level:`, `comments:`, `stereo_coding:`, and `predictor:`.
- OGG Vorbis uses optional `ogg-ruby` and `vorbis` gems. Use `Wavify::Codecs.available_formats` or `wavify doctor` to check whether they are installed.
- Raw PCM/float requires `format:` for read, stream read, and metadata.
