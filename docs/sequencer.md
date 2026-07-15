# Sequencer

The sequencing DSL is intentionally small: it is for Ruby scripts that sketch arrangements, not a full DAW.

```ruby
song = Wavify::DSL.build_definition(format: Wavify::Core::Format::CD_QUALITY, tempo: 116, swing: 0.55) do
  sample_folder "samples"
  key :c, :minor

  track :kick do
    synth :sine
    notes "C2/8. . C2/8t .", resolution: 16
    envelope attack: 0.001, decay: 0.05, sustain: 0.0, release: 0.06
    gain(-4)
  end

  track :pad do
    chords ["Cmaj7/E@drop2", "Abmaj7"], voicing: :open
  end

  arrange do
    section :intro, bars: 1, tracks: %i[kick], repeat: 2, markers: [:start]
    section :bridge, bars: 1, tracks: %i[kick pad], tempo: 92, beats_per_bar: 3, markers: [:bridge]
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
Use `x?50` for a 50% render probability and `x:3` for ratchets. Pass `random_seed:` to `Wavify::DSL.build_definition`, `Wavify::DSL.validate`, or `Wavify.build` for reproducible probability rolls. Note tokens can use duration suffixes such as `C4/8`, dotted values such as `C4/8.`, triplets such as `C4/8t`, and simple ties such as `D4~ D4`.
Use `key :c, :minor` to quantize notes/chords to a scale. Chords support slash inversions and voicings with `@open`, `@drop2`, or the `voicing:` option.
Arrangement sections can override `tempo:` and `beats_per_bar:` and expose marker events through `markers:`.
Use `tracks: []` for an explicit full-section rest. DSL renders and stems are padded with silence through the complete planned song duration, including trailing rest sections.
`preset :lofi_drums` creates a small sample-backed drum track definition using `kick.wav`, `snare.wav`, and `hat.wav`.
Swing starts at `0.5` for straight timing and applies to off-beat steps on even pattern/note grids.
`sample_folder` resolves `sample :kick` to `kick.wav` under that folder, and `pitch:` shifts samples by semitones using resample-based playback speed changes. Use `Wavify::DSL.validate(format: ...)` to catch notation, track, and arrangement errors before rendering.
Use `Wavify::DSL.effect(:name, MyEffect)` to make custom processors available to track-level `effect :name` calls.
Use `song.timeline_text` or `wavify timeline song.rb --seed 123` for quick terminal inspection, and `timeline_json` for visualization tools. Both `wavify render` and `wavify timeline` accept `--seed` and pass it to `random_seed:`.

Trigger steps (`x`/`X`) produce audio on sample-backed DSL tracks. The lower-level sequencer engine still exposes trigger events in its timeline, but synth tracks render only note and chord events.

Keep song logic in Ruby when the DSL does not expose a feature yet. This keeps the core DSL small and avoids locking early ideas into public syntax too soon.
