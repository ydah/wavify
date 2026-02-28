#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require_relative "../lib/wavify"

OUTPUT_DIR = File.expand_path("../tmp/examples", __dir__)

def usage
  puts <<~TEXT
    Usage:
      ruby examples/format_convert.rb INPUT_PATH OUTPUT_PATH [preset]

    Presets:
      cd16     -> stereo / 44.1kHz / 16-bit PCM
      voice    -> mono / 16kHz / 16-bit PCM
      float32  -> stereo / 44.1kHz / 32-bit float (WAV recommended)

    When no arguments are given, a self-contained demo is generated in tmp/examples/.
  TEXT
end

def preset_format(name)
  case name&.downcase
  when nil, ""
    nil
  when "cd16"
    Wavify::Core::Format::CD_QUALITY
  when "voice"
    Wavify::Core::Format::VOICE
  when "float32"
    Wavify::Core::Format.new(channels: 2, sample_rate: 44_100, bit_depth: 32, sample_format: :float)
  else
    raise ArgumentError, "unknown preset: #{name.inspect}"
  end
end

def convert_file(input_path, output_path, preset_name)
  audio = Wavify::Audio.read(input_path)
  target_format = preset_format(preset_name) || audio.format
  converted = audio.convert(target_format)
  converted.write(output_path)

  puts "Converted #{input_path} -> #{output_path}"
  puts "  source: #{audio.format.inspect} / #{audio.duration}"
  puts "  target: #{converted.format.inspect} / #{converted.duration}"
end

def build_demo_audio
  format = Wavify::Core::Format.new(channels: 2, sample_rate: 44_100, bit_depth: 32, sample_format: :float)
  lead = Wavify::Audio.tone(frequency: 440.0, duration: 1.2, waveform: :sine, format: format).gain(-8)
  harmony = Wavify::Audio.tone(frequency: 659.25, duration: 1.2, waveform: :triangle, format: format).gain(-14)
  Wavify::Audio.mix(lead, harmony).fade_in(0.02).fade_out(0.08)
end

def run_demo
  FileUtils.mkdir_p(OUTPUT_DIR)

  source_path = File.join(OUTPUT_DIR, "format_convert_demo_source.wav")
  output_path = File.join(OUTPUT_DIR, "format_convert_demo_output.aiff")
  target_format = Wavify::Core::Format.new(channels: 2, sample_rate: 48_000, bit_depth: 24, sample_format: :pcm)

  demo = build_demo_audio
  demo.write(source_path)
  Wavify::Audio.read(source_path).convert(target_format).write(output_path)

  puts "Generated demo files:"
  puts "  #{source_path}"
  puts "  #{output_path}"
end

if ARGV.include?("-h") || ARGV.include?("--help")
  usage
  exit(0)
end

if ARGV.length >= 2
  convert_file(ARGV[0], ARGV[1], ARGV[2])
else
  run_demo
end
