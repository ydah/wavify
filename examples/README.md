# Examples

Examples are self-contained and write generated files under `tmp/examples/`.

```bash
ruby examples/synth_pad.rb
ruby examples/drum_machine.rb
ruby examples/audio_processing.rb
ruby examples/format_convert.rb
ruby examples/chill_vibes.rb
ruby examples/hybrid_arrangement.rb
ruby examples/streaming_master_chain.rb
ruby examples/cinematic_transition.rb
```

The examples cover these current APIs:

- `format_convert.rb`: windowed-sinc resampling and deterministic TPDF dither
- `audio_processing.rb`: immutable transforms and `MasteringChain`
- `synth_pad.rb`: chord voicing, AHDSR curves, effects, and mastering
- `drum_machine.rb`: arranged synth tracks, section repeats, and markers
- `chill_vibes.rb`: sample patterns, probability, ratchets, and deep validation
- `hybrid_arrangement.rb`: sample/synth arrangements with section tempo changes
- `streaming_master_chain.rb`: float workspaces, stateful processors, meter/progress, and named pipeline steps
- `cinematic_transition.rb`: unclipped float layering and final limiting

Syntax-check every example and run the four shorter smoke examples:

```bash
bundle exec rake docs:examples
```

Run all eight examples end to end:

```bash
EXAMPLES=all bundle exec rake docs:examples
```

The default smoke set is:

- `synth_pad.rb`
- `drum_machine.rb`
- `audio_processing.rb`
- `format_convert.rb`

The arrangement examples render longer audio and are intentionally not executed by the default smoke task, but they are always syntax-checked.
