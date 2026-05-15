# Sequencer

The sequencing DSL is intentionally small: it is for Ruby scripts that sketch arrangements, not a full DAW.

```ruby
song = Wavify::DSL.build_definition(format: Wavify::Core::Format::CD_QUALITY, tempo: 116, swing: 0.55) do
  sample_folder "samples"

  track :kick do
    synth :sine
    notes "C2 . . . C2 . . .", resolution: 16
    envelope attack: 0.001, decay: 0.05, sustain: 0.0, release: 0.06
    gain(-4)
  end

  arrange do
    section :intro, bars: 1, tracks: %i[kick], repeat: 2
  end
end

song.duration
song.timeline_json
song.timeline_text
song.render(stems: true)
song.render.write("song.wav")
```

Sample tracks can transform individual samples before scheduling:

```ruby
track :drums do
  pattern :kick, "x---x0.5--"
  sample :kick, trim: true, gain: -3, pan: -0.2, pitch: 12, from: 0.01, duration: 0.2
end
```

Pattern velocity suffixes are normalized `0.0..1.0` values. `x` defaults to `0.8`, `X` defaults to `1.0`, and explicit values such as `x0.35` are passed through the sequencer timeline and sample-track renderer.
Swing starts at `0.5` for straight timing and applies to off-beat steps on even pattern/note grids.
`sample_folder` resolves `sample :kick` to `kick.wav` under that folder, and `pitch:` shifts samples by semitones using resample-based playback speed changes. Use `Wavify::DSL.validate(format: ...)` to catch notation, track, and arrangement errors before rendering.
Use `Wavify::DSL.effect(:name, MyEffect)` to make custom processors available to track-level `effect :name` calls.
Use `song.timeline_text` or `wavify timeline song.rb` for quick terminal inspection, and `timeline_json` for visualization tools.

Keep song logic in Ruby when the DSL does not expose a feature yet. This keeps the core DSL small and avoids locking early ideas into public syntax too soon.
