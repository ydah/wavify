# Roadmap

Wavify keeps the core gem focused on pure Ruby audio processing, immutable transforms, streaming, DSP, codec I/O, and a compact sequencing DSL.

## Core

- Keep sample-rate conversion, channel conversion, metadata, and streaming behavior covered by regression tests.
- Prefer pure Ruby implementations that work in scripts and CI without mandatory FFmpeg or SoX.
- Keep optional native dependencies behind codec adapters.

## Codec Ecosystem

- Keep WAV, AIFF/AIFF-C PCM, FLAC, raw PCM, and optional OGG Vorbis in the core gem.
- Build MP3, AAC, FFmpeg, MIDI, and spectrogram support as adapter gems instead of adding mandatory dependencies.
- Continue expanding metadata coverage where it does not require decoding the full payload.

## Sequencer

- Keep the DSL small enough to read as Ruby.
- Add notation only when it maps cleanly to timeline events.
- Prefer timeline export, stems, and sample transforms over DAW-scale editing features.

## Performance

- Use `SampleBuffer#frame_view` and streaming APIs in hot paths.
- Track benchmark reports with `bench:baseline` and scheduled benchmark smoke runs.
- Treat large-file workflows as streaming-first.

## Release Quality

- Keep coverage, docs checks, example smoke tests, release checks, and lint in CI.
- Avoid packaging generated files, fixtures, and editor metadata.
