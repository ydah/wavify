# Benchmarks

This directory contains lightweight benchmark scripts for Wavify's core workflows.

Implemented targets (incremental Phase 6 work):

- `wav_io_benchmark.rb` - WAV read/write and streaming pipeline throughput
- `dsp_effects_benchmark.rb` - DSP effects processing cost
- `flac_benchmark.rb` - FLAC encode/decode and streaming throughput
- `streaming_memory_benchmark.rb` - streaming pipeline memory behavior (sampled RSS)

## Usage

Run directly:

```bash
ruby benchmarks/wav_io_benchmark.rb
ruby benchmarks/dsp_effects_benchmark.rb
ruby benchmarks/flac_benchmark.rb
ruby benchmarks/streaming_memory_benchmark.rb
```

Or via rake tasks:

```bash
rake bench:wav_io
rake bench:dsp
rake bench:flac
rake bench:stream
rake bench:all
```

## Environment Variables

- `KEEP_BENCH_FILES=1` keeps generated files in `tmp/benchmarks/`
- `WAV_IO_ITERATIONS`, `WAV_IO_DURATION`, `WAV_IO_CHUNK`
- `DSP_BENCH_ITERATIONS`, `DSP_BENCH_DURATION`
- `FLAC_BENCH_ITERATIONS`, `FLAC_BENCH_DURATION`, `FLAC_BENCH_CHUNK`
- `STREAM_BENCH_DURATION`, `STREAM_BENCH_CHUNK`

## Notes

- OGG Vorbis audio decode is still incomplete, so it is not benchmarked yet.
- `flac_benchmark.rb` measures the current pure Ruby FLAC implementation (verbatim/fixed subframe selection).
- `streaming_memory_benchmark.rb` reports sampled RSS (`ps`) as an approximation, not a strict peak profiler.
- `wav_io_benchmark.rb` optionally compares WAV read/write throughput with the `wavefile` gem when it is installed (`gem install wavefile`).
