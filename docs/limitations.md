# Limitations

Wavify intentionally stays small and Ruby-first.

- MP3, AAC, and M4A are not part of core. Use an external adapter or a separate conversion step.
- FFmpeg and SoX are not mandatory runtime dependencies.
- OGG Vorbis support depends on `ogg-ruby` and `vorbis`, which require native build support.
- AIFF-C is not supported.
- Raw PCM/float has no embedded metadata. Pass `format:` when reading, streaming, or inspecting metadata.
- Streaming WAV/AIFF/FLAC writes require seekable output IO because headers are finalized after writing samples.
- Resampling currently uses linear interpolation. It is predictable and dependency-free, but not a mastering-grade sample-rate converter.
- The sequencer DSL is intentionally compact and does not aim to replace a DAW.

For large files, prefer `Audio.stream` over `Audio.read` to avoid loading the entire payload into memory.
