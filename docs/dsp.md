# DSP

Built-in DSP components are designed for small scripts and streaming pipelines:

- Oscillator waveforms: sine, square, sawtooth, triangle, pulse, white noise, pink noise
- Envelope: AHDSR with optional `curve: :linear`, `:exp`, or `:log`
- Automation and LFO helpers for time-varying parameters
- Filters: lowpass, highpass, bandpass, notch, peaking, shelves
- Effects: Delay, Reverb, Chorus, Vibrato, Flanger, Phaser, Distortion, Compressor, Limiter, SoftLimiter, NoiseGate, Expander, Tremolo, AutoPan, StereoWidener, Bitcrusher, EQ
- Preset chains: MasteringChain, PodcastChain

Effects use the processor protocol:

```ruby
effect.process(buffer)
effect.reset
effect.flush(format: buffer.format)
```

`flush` emits the remaining tail for stateful effects such as delay, reverb, and chorus. Streaming pipelines call `reset` at the start of a stream pass and flush processor tails after the input ends.

```ruby
Wavify::Audio.stream("dry.wav")
             .pipe(Wavify::Effects::Delay.beat(:eighth, tempo: 120, feedback: 0.35))
             .pipe(Wavify::Effects::SoftLimiter.new(threshold: 0.85))
             .write_to("wet.wav")
```

Register custom processors with `Wavify::Effects.register(:name, MyEffect)` or a block returning a processor. Registered effects can be built with `Wavify::Effects.build(:name, **params)` and used by the DSL through `Wavify::DSL.effect`.

Use `Wavify::Effects::MasteringChain.new` for a compact EQ/compressor/limiter pass, and `Wavify::Effects::PodcastChain.new` for gate/EQ/compression/limiting on speech.

`Compressor` supports `makeup_gain:`, `knee:` in dB, and `sidechain:` with an `Audio` or `SampleBuffer` detector signal. Its detector gain is stereo-linked to preserve image stability, so it must process complete buffers rather than individual samples. `NoiseGate` and `Expander` use the same frame-linked peak-envelope model with configurable `attack:`, `hold:`, and `release:` timing, preventing zero crossings from opening and closing them. `Reverb` supports `pre_delay:` on the wet path and `width:` for stereo wet width. `Limiter` provides stereo-linked attack/release gain control with configurable `lookahead:` and reports that latency to streaming pipelines. It likewise requires frame-aware `apply`/`process`; `process_sample` is unsupported. `SoftLimiter` uses a rounded zero-latency curve. `Tremolo`, `AutoPan`, `Vibrato`, `Flanger`, and `Phaser` apply LFO modulation, `StereoWidener` adjusts mid/side width, `EQ` chains filters, and `Bitcrusher` reduces bit depth or holds samples for downsampling effects.

The `:headroom` mix strategy derives gain from the actual per-frame peak, so quiet overlaps are not attenuated merely because multiple sources are active. Its default 5 ms smoothing is anticipatory and can affect audio up to 5 ms before a hot overlap; set `headroom_smoothing:` on `Audio.mix` or `Audio#overlay` to adjust it or use `0.0` for immediate gain changes. Headroom is intended for brief overlap peaks: sustained over-full-scale material can remain pinned to the ceiling, so use `Limiter` when continuous gain recovery is required.
`Audio#fade_in`, `Audio#fade_out`, and `Audio#fade` support `curve: :linear`, `:exp`, and `:log`.
Use `audio.with_bit_depth(16, dither: true)` for simple TPDF dither when reducing PCM bit depth; pass `dither_seed:` for deterministic test output.
Use `audio.resample(sample_rate: 48_000, resampler: :windowed_sinc)` when quality matters more than speed.
Use `Wavify::DSP::Automation` for linear parameter curves over time.

`Audio#lufs` and `normalize(mode: :lufs)` use BS.1770 K-weighting, 400 ms blocks, an absolute −70 LUFS gate, and a relative −10 LU gate. Inputs shorter than 400 ms are measured as one partial block, which is a practical extension outside the strict block definition. Oscillators are stateful: consecutive `generate` calls continue phase, and `reset_phase` is required before changing sample rate or reproducing the initial waveform. Triangle oscillators use a bounded cache of additive band-limited wavetables; square and sawtooth use polyBLEP correction.
