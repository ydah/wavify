# DSP

Built-in DSP components are designed for small scripts and streaming pipelines:

- Oscillator waveforms: sine, square, sawtooth, triangle, white noise, pink noise
- Envelope: ADSR
- Filters: lowpass, highpass, bandpass, notch, peaking, shelves
- Effects: Delay, Reverb, Chorus, Distortion, Compressor

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
             .write_to("wet.wav")
```
