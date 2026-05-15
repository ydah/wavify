# Wavify [![Gem Version](https://badge.fury.io/rb/wavify.svg)](https://badge.fury.io/rb/wavify) [![Ruby](https://github.com/ydah/wavify/actions/workflows/ci.yml/badge.svg)](https://github.com/ydah/wavify/actions/workflows/ci.yml)

Wavify is a Ruby audio processing toolkit with immutable transforms, codec I/O, streaming pipelines, DSP effects, and a sequencing DSL.

Use it to:

- Read, inspect, transform, and write audio from Ruby scripts.
- Process large files with streaming pipelines and stateful DSP effects.
- Generate tones, small arrangements, and test fixtures without mandatory FFmpeg or SoX.

## Requirements

- Ruby `>= 3.1`
- Bundler
- Optional native build environment for OGG Vorbis gems (`ogg-ruby`, `vorbis`)

## Installation

Add to your Gemfile:

```ruby
gem "wavify"
```

Then install:

```bash
bundle install
```

Or install directly:

```bash
gem install wavify
```

WAV, AIFF, FLAC, and raw PCM work without OGG dependencies. Add `ogg-ruby` and `vorbis` to your Gemfile only when you need `.ogg` / `.oga` support.

## Quick Start

```ruby
require "wavify"

format = Wavify::Core::Format::CD_QUALITY

audio = Wavify::Audio.tone(
  frequency: 440.0,
  duration: 1.0,
  waveform: :sine,
  format: format
)

audio.fade_in(0.02, curve: :exp).fade_out(0.05, curve: :log).bit_depth(16, dither: true).write("tone.wav")
```

Codec-specific write options are forwarded with `codec_options:`:

```ruby
audio.write("master.flac", codec_options: { block_size: 2048 })
audio.write("preview.ogg", codec_options: { quality: 0.5 })
audio.write("tagged.wav", codec_options: { info: { title: "Tone", artist: "Wavify" } })
audio.write("master.wav", overwrite: false)
```

## Core API

### `Wavify::Audio`

Main constructors:

- `Audio.read(path_or_io, format: nil, codec_options: {}, strict: false, filename: nil)`
- `Audio.metadata(path_or_io, format: nil, codec_options: {}, strict: false, filename: nil)`
- `Audio.info(path_or_io, format: nil, codec_options: {}, strict: false, filename: nil)`
- `Audio.stream(path_or_io, chunk_size: 4096, format: nil, codec_options: {}, strict: false, filename: nil)`
- `Audio.tone(frequency:, duration:, waveform:, format:)`
- `Audio.silence(duration_seconds, format:)`
- `Audio.mix(*audios, strategy: :clip, gains: nil, align: :start)`

Immutable transforms (each also has `!` in-place variants):

- `gain`, `normalize`, `trim`, `fade_in`, `fade_out`, `pan`, `reverse`, `loop`, `apply`
- `concat`, `append`, `prepend`, `overlay`, `crossfade`, `slice`, `crop`, `pad_start`, `pad_end`, `insert_silence`
- `to_mono`, `to_stereo`, `resample`, `bit_depth`, `map_samples`, `map_frames`

Utility methods:

- `convert`, `split(at:)`, `duration`, `sample_frame_count`, `channels`, `sample_rate`, `frames`, `each_frame`
- `peak_amplitude`, `rms_amplitude`, `peak_dbfs`, `rms_dbfs`, `stats`, `silent?`, `clipped?`, `dc_offset`, `zero_crossing_rate`

Mix strategies are `:clip` (default), `:normalize`, `:headroom`, and `:soft_limit`. `gains:` accepts one dB value per source, and `align:` can be `:start`, `:center`, or `:end`.
Use `bit_depth(16, dither: true)` when reducing PCM bit depth and you want simple TPDF dither.

Duration helpers:

```ruby
Wavify.ms(250)
Wavify.seconds(3)
Wavify::Core::Duration.parse("1:23.456")
```

### Streaming pipeline

```ruby
Wavify::Audio.stream("input.wav", chunk_size: 4096)
             .pipe(Wavify::Effects::Compressor.new(threshold: -18, ratio: 3.0), name: :comp)
             .map_chunks(name: :trim_preview) { |chunk| Wavify::Audio.new(chunk).trim(threshold: 0.005).buffer }
             .meter { |stats| puts stats[:peak_dbfs] }
             .tee("preview.wav")
             .write_to("output.aiff", format: Wavify::Core::Format::CD_QUALITY)
```

`pipe` accepts processors that respond to `call`, `process`, or `apply`.
Stateful processors may implement `reset`, `flush(format:)`, and `tail_duration`.
Use `take_duration`, `drop_duration`, `to_audio`, `progress`, `meter`, `tee`, and `pipeline_steps` for common chunk workflows and inspection.
Use `dry_run(format:)` to validate a stream pipeline without writing output.

`write_to` also accepts codec-specific output options:

```ruby
stream.write_to("output.flac", codec_options: { block_size_strategy: :fixed, block_size: 2048 })
```

## Format Support

| Format | Read | Write | Stream Read | Stream Write | Notes |
|--------|------|-------|-------------|--------------|-------|
| WAV | ✅ | ✅ | ✅ | ✅ | PCM + float WAV, including extensible WAV |
| AIFF | ✅ | ✅ | ✅ | ✅ | PCM only (AIFC unsupported) |
| FLAC | ✅ | ✅ | ✅ | ✅ | Pure Ruby implementation |
| OGG Vorbis | ✅ | ✅ | ✅ | ✅ | Optional `ogg-ruby` + `vorbis` gems |
| Raw PCM/Float | ✅* | ✅ | ✅* | ✅ | `format:` is required for read/stream-read/metadata |

Raw example:

```ruby
raw_format = Wavify::Core::Format.new(channels: 2, sample_rate: 44_100, bit_depth: 16, sample_format: :pcm)
audio = Wavify::Audio.read("input.pcm", format: raw_format)
audio.write("output.wav")
```

For IO objects without magic bytes, pass `filename:` as a codec hint:

```ruby
io = StringIO.new(raw_bytes)
audio = Wavify::Audio.read(io, filename: "input.raw", format: raw_format)
```

Metadata example:

```ruby
metadata = Wavify::Audio.metadata("input.wav")
metadata[:format].sample_rate
metadata[:duration]
```

Codec registry helpers:

```ruby
Wavify::Codecs.supported_formats
Wavify::Codecs.available_formats
Wavify::Codecs.detect("input.wav")
Wavify::Codecs.register(".custom", MyCodec)
```

### OGG Vorbis notes

- `read` / `stream_read` support sequential chained streams and interleaved multi-stream OGG.
- Interleaved multi-stream decode is mixed into one output stream.
- If interleaved streams have different sample rates, they are resampled to the first logical stream's sample rate before mix.
- `decode_mode: :strict` and `decode_mode: :placeholder` are accepted for API compatibility.
- OGG support is optional; `wavify doctor` reports whether the native gems are installed.

## Sequencer DSL

Use `Wavify.build` for one-shot rendering/writing, or `Wavify::DSL.build_definition` when you want timeline access.

```ruby
song = Wavify::DSL.build_definition(format: Wavify::Core::Format::CD_QUALITY, tempo: 116, swing: 0.55, default_bars: 2) do
  sample_folder "samples"

  track :kick do
    synth :sine
    notes "C2 . . . C2 . . .", resolution: 16
    envelope attack: 0.001, decay: 0.05, sustain: 0.0, release: 0.06
    gain(-4)
  end

  arrange do
    section :intro, bars: 1, tracks: %i[kick]
  end
end

timeline = song.timeline
song.timeline_json
stems = song.render(stems: true)
mix = song.render
mix.write("song.wav")
```

Pattern steps support rests (`-`/`.`), normal triggers (`x`, velocity `0.8`), accents (`X`, velocity `1.0`), and explicit normalized velocity suffixes such as `x0.5` or `X0.9`.
Swing values start at `0.5` for straight timing; values such as `0.55` delay off-beat steps on even grids.
Sample tracks can use `sample_folder`, per-sample `pitch:` semitones, and `Wavify::DSL.validate` for pre-render checks.

## DSP

Built-in modules:

- Oscillator waveforms: `:sine`, `:square`, `:sawtooth`, `:triangle`, `:white_noise`, `:pink_noise`
- Envelope (ADSR)
- Biquad filters (lowpass/highpass/bandpass/notch/peaking/shelves)
- Effects: `Delay`, `Reverb`, `Chorus`, `Distortion`, `Compressor`, `Limiter`, `SoftLimiter`, `NoiseGate`, `Expander`, `Tremolo`, `AutoPan`, `StereoWidener`, `Bitcrusher`, `EQ`

Register custom processors for pipelines and DSL tracks:

```ruby
Wavify::Effects.register(:my_effect, MyEffect)
Wavify::DSL.effect(:my_effect, MyEffect)
```

## Examples

Scripts in `examples/`:

- `examples/format_convert.rb`
- `examples/audio_processing.rb`
- `examples/synth_pad.rb`
- `examples/drum_machine.rb`
- `examples/chill_vibes.rb`
- `examples/hybrid_arrangement.rb`
- `examples/streaming_master_chain.rb`
- `examples/cinematic_transition.rb`

Run:

```bash
ruby examples/synth_pad.rb
```

See `examples/README.md` for the full list.

## CLI

The gem includes a small CLI for common scripting tasks:

```bash
wavify info input.wav
wavify convert input.wav output.flac
wavify tone --freq 440 --duration 1 tone.wav
wavify normalize input.wav output.wav --target -1
wavify trim input.wav output.wav --threshold 0.01
wavify chain input.wav output.wav --gain -3 --fade-in 0.02 --fade-out 0.05
wavify render song.rb out.wav --tempo 120 --swing 0.55 --bars 4
wavify formats
wavify doctor
```

## Documentation

- `docs/getting-started.md`
- `docs/codecs.md`
- `docs/dsp.md`
- `docs/streaming.md`
- `docs/sequencer.md`
- `docs/limitations.md`
- `docs/performance.md`
- YARD docs can be generated with `bundle exec rake docs:yard`.

## Limitations

- MP3, AAC, and M4A are not built into core.
- FFmpeg and SoX are not mandatory runtime dependencies.
- OGG Vorbis uses optional native gems (`ogg-ruby`, `vorbis`).
- Raw PCM/float requires `format:` for read, stream read, and metadata.
- Streaming writes for header-based formats require seekable output IO.
- Resampling currently uses linear interpolation.

## Development

Install dependencies:

```bash
bundle install
```

Run tests:

```bash
bundle exec rspec
bundle exec rake spec:coverage COVERAGE_MINIMUM=90
```

Generate/check docs:

```bash
bundle exec rake docs:examples
bundle exec rake docs:yard
YARD_MINIMUM=85 bundle exec rake docs:check
bundle exec rake docs:all
```

`docs:examples` smoke-runs the self-contained example scripts. `docs:yard` generates YARD output under `doc/`. `docs:check` enforces the configured YARD documentation percentage.

Benchmarks:

```bash
bundle exec rake bench:wav_io
bundle exec rake bench:dsp
bundle exec rake bench:flac
bundle exec rake bench:stream
bundle exec rake bench:all
```

Release checks:

```bash
bundle exec rake release:check
```

## License

Wavify is released under the MIT License.
