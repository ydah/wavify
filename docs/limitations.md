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
- `Audio#lufs` and `normalize(mode: :lufs)` are lightweight mean-square loudness estimates. They do not implement BS.1770 K-weighting or gating.
- `Limiter` is a zero-latency hard peak clipper without attack, release, or lookahead. Use `SoftLimiter` when a rounded transfer curve is preferable.
- The triangle oscillator is generated directly and can alias at high frequencies; square and sawtooth use polyBLEP correction.
- The pure Ruby FLAC writer favors portability over maximum compression. Predictor selection and Rice partitioning are simpler than production encoders such as libFLAC.
- The sequencer DSL is intentionally compact and does not aim to replace a DAW.
- Audio samples are stored as Ruby numeric arrays. Full-buffer transforms can allocate several copies, so streaming is strongly preferred for long files.

For large files, prefer `Audio.stream` over `Audio.read` to avoid loading the entire payload into memory.
