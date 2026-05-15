# Getting Started

Wavify is a pure Ruby audio toolkit for scripts, tests, CI jobs, and small creative audio tools. The core workflow is:

1. Read or generate audio.
2. Apply immutable transforms.
3. Write the result or stream it through processors.

```ruby
require "wavify"

audio = Wavify::Audio.read("input.wav")
processed = audio.normalize(target_db: -1.0)
                 .fade_in(Wavify.ms(20))
                 .fade_out(Wavify.ms(50))

processed.write("output.flac", codec_options: { block_size: 2048 })
```

Use `Audio.stream` for large inputs:

```ruby
Wavify::Audio.stream("input.wav", chunk_size: 4096)
             .pipe(Wavify::Effects::Compressor.new(threshold: -18, ratio: 3.0))
             .write_to("output.wav")
```

Raw PCM has no container metadata, so read and metadata calls require an explicit format:

```ruby
format = Wavify::Core::Format.new(channels: 2, sample_rate: 44_100, bit_depth: 16)
audio = Wavify::Audio.read("input.pcm", format: format)
metadata = Wavify::Audio.metadata("input.pcm", format: format)
```
