# Wavify

Wavify is a Ruby audio processing toolkit with immutable transforms, codec I/O, streaming pipelines, DSP effects, and a sequencing DSL.

## Requirements

- Ruby `>= 3.1`
- Bundler
- Native build environment for gems with C extensions (`ogg-ruby`, `vorbis`)

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

audio.fade_in(0.02).fade_out(0.05).write("tone.wav")
```

## Core API

### `Wavify::Audio`

Main constructors:

- `Audio.read(path, format: nil, codec_options: {})`
- `Audio.stream(path_or_io, chunk_size: 4096, format: nil, codec_options: {})`
- `Audio.tone(frequency:, duration:, waveform:, format:)`
- `Audio.silence(duration_seconds, format:)`
- `Audio.mix(*audios)`

Immutable transforms (each also has `!` in-place variants):

- `gain`, `normalize`, `trim`, `fade_in`, `fade_out`, `pan`, `reverse`, `loop`, `apply`

Utility methods:

- `convert`, `split(at:)`, `peak_amplitude`, `rms_amplitude`, `duration`, `sample_frame_count`

### Streaming pipeline

```ruby
Wavify::Audio.stream("input.wav", chunk_size: 4096)
             .pipe(Wavify::Effects::Compressor.new(threshold: -18, ratio: 3.0))
             .pipe(Wavify::Effects::Chorus.new(rate: 0.5, depth: 0.2, mix: 0.15))
             .write_to("output.aiff", format: Wavify::Core::Format::CD_QUALITY)
```

`pipe` accepts processors that respond to `call`, `process`, or `apply`.

## Format Support

| Format | Read | Write | Stream Read | Stream Write | Notes |
|--------|------|-------|-------------|--------------|-------|
| WAV | ✅ | ✅ | ✅ | ✅ | PCM + float WAV, including extensible WAV |
| AIFF | ✅ | ✅ | ✅ | ✅ | PCM only (AIFC unsupported) |
| FLAC | ✅ | ✅ | ✅ | ✅ | Pure Ruby implementation |
| OGG Vorbis | ✅ | ✅ | ✅ | ✅ | Backed by `ogg-ruby` + `vorbis` |
| Raw PCM/Float | ✅* | ✅ | ✅* | ✅ | `format:` is required for read/stream-read/metadata |

Raw example:

```ruby
raw_format = Wavify::Core::Format.new(channels: 2, sample_rate: 44_100, bit_depth: 16, sample_format: :pcm)
audio = Wavify::Audio.read("input.pcm", format: raw_format)
audio.write("output.wav")
```

### OGG Vorbis notes

- `read` / `stream_read` support sequential chained streams and interleaved multi-stream OGG.
- Interleaved multi-stream decode is mixed into one output stream.
- If interleaved streams have different sample rates, they are resampled to the first logical stream's sample rate before mix.
- `decode_mode: :strict` and `decode_mode: :placeholder` are accepted for API compatibility.

## Sequencer DSL

Use `Wavify.build` for one-shot rendering/writing, or `Wavify::DSL.build_definition` when you want timeline access.

```ruby
song = Wavify::DSL.build_definition(format: Wavify::Core::Format::CD_QUALITY, tempo: 116, default_bars: 2) do
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
mix = song.render
mix.write("song.wav")
```

## DSP

Built-in modules:

- Oscillator waveforms: `:sine`, `:square`, `:sawtooth`, `:triangle`, `:white_noise`, `:pink_noise`
- Envelope (ADSR)
- Biquad filters (lowpass/highpass/bandpass/notch/peaking/shelves)
- Effects: `Delay`, `Reverb`, `Chorus`, `Distortion`, `Compressor`

## Examples

Scripts in `examples/`:

- `examples/format_convert.rb`
- `examples/audio_processing.rb`
- `examples/synth_pad.rb`
- `examples/drum_machine.rb`

Run:

```bash
ruby examples/synth_pad.rb
```

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
