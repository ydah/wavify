#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "benchmark_helper"

helper = WavifyBenchmarks::Helper
iterations = helper.int_env("WAV_IO_ITERATIONS", 5)
duration_seconds = helper.float_env("WAV_IO_DURATION", 3.0)
chunk_size = helper.int_env("WAV_IO_CHUNK", 4096)

wavefile_loaded = begin
  require "wavefile"
  true
rescue LoadError
  false
end

def wavefile_format_for(format)
  channels = case format.channels
             when 1 then :mono
             when 2 then :stereo
             else format.channels
             end

  sample_format = if format.sample_format == :pcm
                    :"pcm_#{format.bit_depth}"
                  elsif format.sample_format == :float && format.bit_depth == 32
                    :float
                  else
                    raise ArgumentError, "unsupported WaveFile benchmark format: #{format.sample_format}/#{format.bit_depth}"
                  end

  WaveFile::Format.new(channels, sample_format, format.sample_rate)
end

def wavefile_buffer_for(audio)
  format = audio.format
  frame_samples = audio.buffer.samples.each_slice(format.channels).map(&:dup)
  WaveFile::Buffer.new(frame_samples, wavefile_format_for(format))
end

helper.banner("WAV IO benchmark")
helper.print_config(
  iterations: iterations,
  duration_seconds: duration_seconds,
  chunk_size: chunk_size,
  wavefile_compare: wavefile_loaded
)

source_audio = helper.demo_audio(duration_seconds: duration_seconds, format: helper.float_stereo_format)
source_audio = source_audio.convert(helper.pcm_stereo_format)

source_path = File.join(helper.tmp_dir, "wav_io_source.wav")
processed_path = File.join(helper.tmp_dir, "wav_io_processed.wav")
wavefile_path = File.join(helper.tmp_dir, "wav_io_wavefile.wav")

wavify_write_elapsed, = helper.measure("write source x#{iterations}") do
  iterations.times { source_audio.write(source_path) }
end

wavify_read_elapsed, = helper.measure("read source x#{iterations}") do
  iterations.times { Wavify::Audio.read(source_path) }
end

helper.measure("stream read+write x#{iterations}") do
  iterations.times do
    Wavify::Audio.stream(source_path, chunk_size: chunk_size)
                 .pipe(helper.gain_chunk_processor(-3.0))
                 .pipe(Wavify::Effects::Compressor.new(threshold: -16, ratio: 2.0, attack: 0.005, release: 0.05))
                 .write_to(processed_path, format: helper.pcm_stereo_format)
  end
end

puts "  source file size:    #{helper.file_size_mb(source_path).round(2)} MB"
puts "  processed file size: #{helper.file_size_mb(processed_path).round(2)} MB"

if wavefile_loaded
  wavefile_format = wavefile_format_for(source_audio.format)
  wavefile_buffer = wavefile_buffer_for(source_audio)

  wavefile_write_elapsed, = helper.measure("WaveFile write x#{iterations}") do
    iterations.times do
      WaveFile::Writer.new(wavefile_path, wavefile_format) do |writer|
        writer.write(wavefile_buffer)
      end
    end
  end

  wavefile_read_elapsed, = helper.measure("WaveFile read x#{iterations}") do
    iterations.times do
      WaveFile::Reader.new(wavefile_path) do |reader|
        reader.each_buffer(chunk_size) { |_buffer| }
      end
    end
  end

  if wavify_write_elapsed.positive?
    puts format("  Wavify/WaveFile write speed: %7.2f%%",
                (wavefile_write_elapsed / wavify_write_elapsed) * 100.0)
  end
  if wavify_read_elapsed.positive?
    puts format("  Wavify/WaveFile read speed:  %7.2f%%",
                (wavefile_read_elapsed / wavify_read_elapsed) * 100.0)
  end
else
  puts "  WaveFile comparison skipped (optional gem not installed)"
  puts "  Install with: gem install wavefile"
end

helper.maybe_cleanup(source_path, processed_path, wavefile_path)
