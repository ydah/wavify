# DSP

Built-in DSP components are designed for small scripts and streaming pipelines:

- Oscillator waveforms: sine, square, sawtooth, triangle, white noise, pink noise
- Envelope: ADSR
- Filters: lowpass, highpass, bandpass, notch, peaking, shelves
- Effects: Delay, Reverb, Chorus, Distortion, Compressor, Limiter, SoftLimiter, NoiseGate, Tremolo, Bitcrusher

Effects use the processor protocol:

```ruby
effect.process(buffer)
effect.reset
effect.flush(format: buffer.format)
```

`flush` emits the remaining tail for stateful effects such as delay, reverb, and chorus. Streaming pipelines call `reset` at the start of a stream pass and flush processor tails after the input ends.

```ruby
Wavify::Audio.stream("dry.wav")
             .pipe(Wavify::Effects::Delay.new(time: 0.25, feedback: 0.35))
             .pipe(Wavify::Effects::SoftLimiter.new(threshold: 0.85))
             .write_to("wet.wav")
```

`Compressor` supports `makeup_gain:` and `knee:` in dB. `Limiter` and `SoftLimiter` are peak-control processors, `NoiseGate` attenuates low-level noise, `Tremolo` applies sine-LFO amplitude modulation, and `Bitcrusher` reduces bit depth or holds samples for downsampling effects.
