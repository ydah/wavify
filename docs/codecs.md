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
```

Codec registration is intentionally small:

```ruby
Wavify::Codecs.register(".custom", MyCodec)
```

Custom codecs should expose `read`, `write`, `stream_read`, `stream_write`, and `metadata`.

## Format Notes

- WAV supports PCM and float WAV, including extensible WAV.
- AIFF supports PCM AIFF. AIFF-C is intentionally unsupported.
- FLAC is implemented in pure Ruby.
- OGG Vorbis uses `ogg-ruby` and `vorbis`.
- Raw PCM/float requires `format:` for read, stream read, and metadata.
