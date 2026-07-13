# Changelog

All notable changes to this project will be documented in this file.

The format is based on Keep a Changelog and this project adheres to Semantic Versioning.

## [Unreleased]

### Added

- Added reproducible sequencer probability rolls through `random_seed:`.
- Added `repeat`/`repeat!`, `with_bit_depth`, value equality, and reversible codec/effect registries.

### Changed

- Enabled the RuboCop Lint department and tightened gem package/release checks.
- Improved streaming reuse rules, DSP state handling, codec validation, and full-buffer analysis allocations.

### Fixed

- Fixed zero-duration fades, PCM endpoint conversion, clipping detection, duration parsing, oscillator continuity/unison/noise behavior, and uppercase major chord parsing.
- Fixed WAV extensible/RF64/overflow metadata handling, FLAC checksum validation, raw stream alignment, and destructive caller-owned IO writes.
- Fixed sequencer release tails, chord/track headroom, pattern probability, duplicate tracks, preset sample paths, and stream tail duration limits.
- Fixed CLI option ordering, help/version exit behavior, optional OGG test setup, and codec/effect registry synchronization.

## [0.1.0] - 2026-03-04

- Initial release
