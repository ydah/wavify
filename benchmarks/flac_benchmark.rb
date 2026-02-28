#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "benchmark_helper"

helper = WavifyBenchmarks::Helper
iterations = helper.int_env("FLAC_BENCH_ITERATIONS", 4)
duration_seconds = helper.float_env("FLAC_BENCH_DURATION", 3.0)
chunk_size = helper.int_env("FLAC_BENCH_CHUNK", 4096)
format = helper.pcm_stereo_format

source_audio = helper.demo_audio(duration_seconds: duration_seconds, format: helper.float_stereo_format)
source_audio = source_audio.convert(format)

wav_source_path = File.join(helper.tmp_dir, "flac_bench_source.wav")
flac_path = File.join(helper.tmp_dir, "flac_bench_audio_write.flac")
flac_stream_path = File.join(helper.tmp_dir, "flac_bench_stream_write.flac")

helper.banner("FLAC encode/decode benchmark")
helper.print_config(
  iterations: iterations,
  duration_seconds: duration_seconds,
  chunk_size: chunk_size,
  sample_rate: format.sample_rate,
  channels: format.channels,
  bit_depth: format.bit_depth
)

helper.measure("prepare wav source") do
  source_audio.write(wav_source_path, format: format)
end

helper.measure("audio.write(.flac) x#{iterations}") do
  iterations.times do
    source_audio.write(flac_path, format: format)
  end
end

helper.measure("audio.read(.flac) x#{iterations}") do
  iterations.times { Wavify::Audio.read(flac_path) }
end

helper.measure("stream wav->flac x#{iterations}") do
  iterations.times do
    Wavify::Codecs::Flac.stream_write(flac_stream_path, format: format) do |writer|
      Wavify::Codecs::Wav.stream_read(wav_source_path, chunk_size: chunk_size) do |chunk|
        writer.call(chunk)
      end
    end
  end
end

helper.measure("stream read flac x#{iterations}") do
  iterations.times do
    total_frames = 0
    Wavify::Codecs::Flac.stream_read(flac_stream_path, chunk_size: chunk_size) do |chunk|
      total_frames += chunk.sample_frame_count
    end
    total_frames
  end
end

metadata = Wavify::Codecs::Flac.metadata(flac_path)
wav_size_mb = helper.file_size_mb(wav_source_path)
flac_size_mb = helper.file_size_mb(flac_path)
ratio = wav_size_mb.zero? ? 0.0 : (flac_size_mb / wav_size_mb)

puts "  source frames:       #{source_audio.sample_frame_count}"
puts "  wav source size:     #{wav_size_mb.round(2)} MB"
puts "  flac write size:     #{flac_size_mb.round(2)} MB"
puts "  flac/wav ratio:      #{ratio.round(3)}"
puts "  flac block size:     #{metadata[:min_block_size]}..#{metadata[:max_block_size]}"

helper.maybe_cleanup(wav_source_path, flac_path, flac_stream_path)
