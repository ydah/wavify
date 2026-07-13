# Limitations

Wavify intentionally stays small and Ruby-first.

- MP3, AAC, and M4A are not part of core. Use an external adapter or a separate conversion step.
- FFmpeg and SoX are not mandatory runtime dependencies.
- OGG Vorbis support is optional and depends on `ogg-ruby` and `vorbis`, which require native build support.
- AIFF-C support is limited to uncompressed PCM variants (`NONE` and `sowt`).
- Raw PCM/float has no embedded metadata. Pass `format:` when reading, streaming, or inspecting metadata.
- Streaming WAV/AIFF/FLAC writes require seekable output IO because headers are finalized after writing samples.
- A stream backed by a path can be enumerated repeatedly. A caller-owned IO is rewound between passes when possible; a non-rewindable IO is single-use and raises on a second pass.
- Resampling defaults to linear interpolation. Use `resampler: :windowed_sinc` for higher-quality offline conversion when speed is less important.
- The sequencer DSL is intentionally compact and does not aim to replace a DAW.
- The default sample storage remains a Ruby numeric array for API compatibility. Packed storage is opt-in, and full-buffer transforms still materialize working arrays; prefer streaming for long processing pipelines.

For large files, prefer `Audio.stream` over `Audio.read` to avoid loading the entire payload into memory.
