# Roadmap

This roadmap keeps Wavify focused on pure Ruby audio workflows.

## v0.2 Correctness and Trust

- Keep sample-rate conversion explicit and tested.
- Keep write-side codec options aligned with read/stream options.
- Expose metadata and codec registry helpers.
- Document current limitations and recommended streaming workflows.
- Run specs, coverage, docs, examples, and release checks in CI.

## v0.3 Streaming and DSP Polish

- Refine the processor protocol around `process`, `reset`, `flush`, `tail_duration`, `latency`, and `lookahead`.
- Add focused DSP processors such as limiter, soft limiter, noise gate, tremolo, and bitcrusher.
- Add fade curve options and bit-depth dither.
- Keep streaming and offline behavior covered by comparison tests.

## v0.4 Sequencer Identity

- Keep swing, velocity, arrangement repeat, timeline export, and improved DSL error context cohesive.
- Add stems rendering when the track model is stable enough.
- Keep the DSL compact and Ruby-native.

## v0.5 Ecosystem

- Expand the small CLI beyond `info`, `convert`, `tone`, `normalize`, `trim`, `formats`, and `doctor` only when workflows justify it.
- Keep MP3/AAC/FFmpeg support in optional adapters.
- Grow codec/effect plugin APIs only after real adapter use cases appear.
- Publish benchmark snapshots from stable benchmark scripts.

## Not Planned for Core

- Mandatory FFmpeg or SoX dependency.
- Full DAW-style UI or plugin host behavior.
- Native extensions as a requirement for core DSP.
- Large fixture files packaged in the gem.
