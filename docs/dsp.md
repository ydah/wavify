# DSP

Built-in DSP components are designed for small scripts and streaming pipelines:

- Oscillator waveforms: sine, square, sawtooth, triangle, white noise, pink noise
- Envelope: ADSR
- Filters: lowpass, highpass, bandpass, notch, peaking, shelves
- Effects: Delay, Reverb, Chorus, Distortion, Compressor, Limiter, SoftLimiter, NoiseGate, Expander, Tremolo, AutoPan, StereoWidener, Bitcrusher, EQ

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

`Compressor` supports `makeup_gain:` and `knee:` in dB. `Limiter` and `SoftLimiter` are peak-control processors, `NoiseGate` and `Expander` attenuate low-level noise, `Tremolo` and `AutoPan` apply sine-LFO modulation, `StereoWidener` adjusts mid/side width, `EQ` chains filters, and `Bitcrusher` reduces bit depth or holds samples for downsampling effects.
`Audio#fade_in`, `Audio#fade_out`, and `Audio#fade` support `curve: :linear`, `:exp`, and `:log`.
Use `audio.bit_depth(16, dither: true)` for simple TPDF dither when reducing PCM bit depth; pass `dither_seed:` for deterministic test output.
