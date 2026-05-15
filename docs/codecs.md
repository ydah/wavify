# Codecs

Wavify supports WAV, AIFF, FLAC, OGG Vorbis, and raw PCM/float.

```ruby
Wavify::Codecs.supported_formats
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
- WAV metadata exposes `info:` from LIST/INFO chunks and normalized `loops:` from `smpl` chunks.
- AIFF supports PCM AIFF. AIFF-C is intentionally unsupported.
- FLAC is implemented in pure Ruby.
- OGG Vorbis uses `ogg-ruby` and `vorbis`.
- Raw PCM/float requires `format:` for read, stream read, and metadata.
