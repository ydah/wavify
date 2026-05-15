# Examples

Examples write generated files under `tmp/examples/`.

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

Run the short smoke examples through the development task:

```bash
bundle exec rake docs:examples
```

Use the shorter examples first:

- `synth_pad.rb`
- `drum_machine.rb`
- `audio_processing.rb`
- `format_convert.rb`

Use the arrangement examples when testing the DSL and longer rendering flows; they are intentionally not part of the default smoke task.
