# Changelog

All notable changes to this project will be documented in this file.

The format is based on Keep a Changelog and this project adheres to Semantic Versioning.

## [Unreleased]

## [0.2.0] - 2026-07-16

### Added

- Added the `wavify` CLI with info, conversion, tone generation, processing, DSL rendering/timeline, format, and dependency-diagnostic commands.
- Expanded `Audio` with timeline editing, repeat, channel/bit-depth/sample-rate conversion, dither, sample/frame mapping, stereo controls, configurable mixing, value semantics, and peak/RMS/LUFS/true-peak analysis.
- Expanded streaming pipelines with named steps, duration windows, meters, progress, tees, materialization, dry runs, and reset/flush/latency handling for stateful processors.
- Added public codec metadata and reversible codec registries, strict magic/extension checks, filename hints for IO, codec-specific options, and atomic no-overwrite output.
- Added WAV LIST/INFO, cue, loop, BWF, RF64, valid-bit, and channel-layout metadata; AIFF-C, marker, and instrument-loop support; FLAC comments, stereo coding, LPC, and adaptive Rice encoding; and configurable raw PCM/float byte order and numeric domains.
- Added `Automation`, `LFO`, BS.1770 `LoudnessMeter`, `Processor`, and headroom helpers, plus limiter, gate, expansion, modulation, stereo, EQ, bitcrusher, and mastering/podcast chain effects.
- Expanded the sequencer and DSL with swing, velocity/probability/ratchet notation, note durations and ties, keys/scales, chord inversions and voicings, sample transforms, stems, repeatable tempo/meter sections, markers, explicit rests, timeline text/JSON, validation, and reproducible seeds.
- Added format valid-bit/channel-layout metadata (including explicit unknown layouts), lazy sample-buffer views, optional packed storage, cached value hashing, and thread-safe value equality.
- Added reversible effect registration and optional adapter discovery for external codec, MIDI, and analysis integrations.
- Added namespace-split RBS signatures, public API parity checks, documentation guides, expanded examples, randomized/property tests, and branch/per-file coverage gates.

### Changed

- Made OGG Vorbis an optional dependency; chained/interleaved streams now decode incrementally where possible, resample to a common rate, and spool multi-stream input outside the Ruby heap.
- Standardized codec read/write/stream/metadata contracts and processor `flush(format:)` behavior, including defined stream-source reuse semantics and isolated offline DSP runtimes.
- Kept mixing, automation, effect chains, and sequencer buses in floating-point workspaces until their output boundary, with signal-aware headroom and linked master limiting.
- Improved oscillator generation with polyBLEP waveforms and band-limited/interpolated wavetables, and improved FLAC compression with Levinson–Durbin LPC and adaptive Rice partition search.
- Reduced allocations in audio analysis, format conversion, slicing, streaming codecs, OGG demultiplexing, and sequencer voice rendering while bounding eager allocations and parser resource use.
- Moved general `InvalidParameterError` failures outside the DSP-specific error hierarchy.
- Made gem packaging independent of Git metadata, tied release links to the version tag, strengthened release installation checks, and made the default Rake task run the local quality gate.
- Expanded CI across supported Ruby/platform/dependency combinations, pinned actions/runners, strengthened lint and coverage checks, and added repeatable benchmark reports.

### Removed

- Removed the no-op OGG `decode_mode:` option; OGG reads now always perform full decoding.
- Removed `Audio#loop`/`loop!`; use `repeat`/`repeat!` instead.

### Fixed

- Fixed PCM endpoint conversion, resampling, duration parsing, zero-duration fades, clipping detection, metadata coordinate projection, packed-buffer concurrency, and destructive writes to caller-owned IO.
- Fixed WAV extensible/RF64/overflow handling, AIFF sample-width and bounded-read behavior, FLAC checksum validation, raw stream alignment, and OGG parser/tempfile cleanup and mixed-rate chaining.
- Fixed stream duration limits, reusable and non-rewindable source handling, processor error propagation, and cross-platform atomic path output.
- Fixed oscillator continuity/noise behavior, envelope release handling, filter stability, and state consistency across chunked DSP processing.
- Fixed sequencer note/chord release and rest timing, duplicate-track validation, chord parsing, and clipping across voices and simultaneous tracks.

## [0.1.0] - 2026-03-04

- Initial release
