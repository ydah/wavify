#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "benchmark_helper"

helper = WavifyBenchmarks::Helper
duration_seconds = helper.float_env("STREAM_BENCH_DURATION", 30.0)
chunk_frames = helper.int_env("STREAM_BENCH_CHUNK", 4096)
format = helper.pcm_stereo_format
float_chunk_format = format.with(sample_format: :float, bit_depth: 32)
source_path = File.join(helper.tmp_dir, "streaming_source.wav")
output_path = File.join(helper.tmp_dir, "streaming_processed.wav")

def build_large_source(path, duration_seconds:, chunk_frames:, format:, float_chunk_format:)
  total_frames = (duration_seconds * format.sample_rate).round
  remaining = total_frames

  tone = Wavify::DSP::Oscillator.new(waveform: :sine, frequency: 110.0, amplitude: 0.45)
  noise = Wavify::DSP::Oscillator.new(waveform: :white_noise, frequency: 1.0, amplitude: 0.08)
  tone_enum = tone.each_sample(format: float_chunk_format)
  noise_enum = noise.each_sample(format: float_chunk_format)

  Wavify::Codecs::Wav.stream_write(path, format: format) do |writer|
    while remaining.positive?
      frames = [remaining, chunk_frames].min
      samples = Array.new(frames * float_chunk_format.channels)

      frames.times do |frame_index|
        value = tone_enum.next + noise_enum.next
        base = frame_index * float_chunk_format.channels
        float_chunk_format.channels.times do |channel_index|
          samples[base + channel_index] = value.clamp(-1.0, 1.0)
        end
      end

      writer.call(Wavify::Core::SampleBuffer.new(samples, float_chunk_format))
      remaining -= frames
    end
  end

  total_frames
end

helper.banner("Streaming memory benchmark")
helper.print_config(
  duration_seconds: duration_seconds,
  chunk_frames: chunk_frames,
  sample_rate: format.sample_rate,
  channels: format.channels
)

generated_frames = nil
helper.measure("generate streamed source") do
  generated_frames = build_large_source(
    source_path,
    duration_seconds: duration_seconds,
    chunk_frames: chunk_frames,
    format: format,
    float_chunk_format: float_chunk_format
  )
end

rss_before = helper.rss_kb
rss_peak = rss_before
probe_counter = 0

probe = lambda do |chunk|
  probe_counter += 1
  if (probe_counter % 25).zero?
    current_rss = helper.rss_kb
    rss_peak = [rss_peak, current_rss].compact.max
  end
  chunk
end

helper.measure("stream process pipeline") do
  Wavify::Audio.stream(source_path, chunk_size: chunk_frames)
               .pipe(probe)
               .pipe(Wavify::Effects::Compressor.new(threshold: -18, ratio: 3.0, attack: 0.003, release: 0.08))
               .pipe(Wavify::Effects::Chorus.new(rate: 0.5, depth: 0.2, mix: 0.12))
               .pipe(helper.gain_chunk_processor(-2.0))
               .write_to(output_path, format: format)
end

rss_after = helper.rss_kb

puts "  source frames:       #{generated_frames}"
puts "  source file size:    #{helper.file_size_mb(source_path).round(2)} MB"
puts "  output file size:    #{helper.file_size_mb(output_path).round(2)} MB"
puts "  rss before:          #{rss_before || 'n/a'} KB"
puts "  rss peak (sampled):  #{rss_peak || 'n/a'} KB"
puts "  rss after:           #{rss_after || 'n/a'} KB"

helper.maybe_cleanup(source_path, output_path)
