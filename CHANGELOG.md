# Changelog

All notable changes to this project will be documented in this file.

The format is based on Keep a Changelog and this project adheres to Semantic Versioning.

## [Unreleased]

## [0.2.0] - 2026-07-15

### Added

- Added namespace-split RBS signatures with implementation parity checks, randomized codec parser tests, and storage/hash properties.
- Added branch and per-file coverage gates, minimum/latest dependency jobs, and scheduled Ruby head/latest-runner canaries.
- Added reproducible sequencer probability rolls through `random_seed:`.
- Added `repeat`/`repeat!`, `with_bit_depth`, value equality, and reversible codec/effect registries.
- Added BS.1770 K-weighted/gated loudness measurement and optional packed `SampleBuffer` storage.
- Added stereo-linked lookahead limiting with attack, release, latency, and streaming tail support.

### Changed

- Pinned CI actions and stable runner images, made benchmark reports use repeated median/p95 samples, and made the default Rake task run the local quality gate.
- Made gem packaging independent of Git metadata and tied source/changelog metadata to the release version tag.
- Enabled the RuboCop Lint department and tightened gem package/release checks.
- Improved streaming reuse rules, DSP state handling, codec validation, and full-buffer analysis allocations.
- Smoothed overlap-aware headroom gain and reduced limiter lookahead processing to linear time.
- Moved general `InvalidParameterError` failures out of the DSP-specific error hierarchy.
- Replaced triangle generation with a band-limited wavetable and FLAC fixed LPC coefficients with Levinson–Durbin analysis.
- Added adaptive FLAC Rice partition selection and removed frame-array/flatten allocation passes from format conversion.
- Refreshed all runnable examples for current mastering, streaming, conversion, and sequencer APIs, with an opt-in full example smoke run.

### Removed

- Removed the no-op OGG `decode_mode:` option, `Audio#loop` aliases, and the overloaded bit-depth converter; use full OGG decoding, `repeat`, and `with_bit_depth` respectively.

### Fixed

- Fixed release verification to install the built gem in isolation and smoke-test its require path, CLI, signatures, and documentation files.
- Replaced locale-sensitive YARD output parsing with registry-based coverage calculation and documented the native OGG support matrix.
- Fixed zero-duration fades, PCM endpoint conversion, clipping detection, duration parsing, oscillator continuity/unison/noise behavior, and uppercase major chord parsing.
- Fixed WAV extensible/RF64/overflow metadata handling, FLAC checksum validation, raw stream alignment, and destructive caller-owned IO writes.
- Fixed sequencer release tails, chord/track headroom, pattern probability, duplicate tracks, preset sample paths, and stream tail duration limits.
- Fixed arrangement timing across silent track sections, packed-buffer concurrency, projected metadata coordinates, and apply-only effect-chain tails.
- Fixed CLI option ordering, help/version exit behavior, reproducible `--seed` rendering, optional OGG test setup, and codec/effect registry synchronization.
- Fixed Windows path-output coverage by closing destination handles before atomic replacement, and bounded exact codec reads so malformed AIFF sizes stay within the public error contract.
- Fixed sequencer chord and simultaneous-track clipping with per-voice scaling, float mix buses, and final linked limiting, while removing per-sample Enumerator resumes from voice rendering.
- Smoothed NoiseGate gain transitions, separated Limiter window detection from current-frame safety clamps, and isolated offline limiting from active streaming state.
- Restored eager arrangement validation while keeping repeat expansion lazy, and reused sequencer engines across repeated tempo/meter sections.
- Normalized explicit nil channel layouts, made dynamic processor flush dispatch format-aware, and preserved above-full-scale Automation gain in float workspaces.
- Documented unclipped float mixing and silent-by-default WAV/AIFF warnings, and covered OGG tempfile cleanup on parser failures.
- Fixed offline and streaming runtime construction for mastering and podcast preset chains.
- Ramped sequencer master limiting across its lookahead window so isolated peaks do not introduce an early gain discontinuity.
- Accelerated sine generation with an interpolated wavetable and computed sequencer envelopes once per event frame instead of once per voice.

## [0.1.0] - 2026-03-04

- Initial release
