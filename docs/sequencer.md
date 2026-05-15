# Sequencer

The sequencing DSL is intentionally small: it is for Ruby scripts that sketch arrangements, not a full DAW.

```ruby
song = Wavify::DSL.build_definition(format: Wavify::Core::Format::CD_QUALITY, tempo: 116) do
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
song.render(stems: true)
song.render.write("song.wav")
```

Keep song logic in Ruby when the DSL does not expose a feature yet. This keeps the core DSL small and avoids locking early ideas into public syntax too soon.
