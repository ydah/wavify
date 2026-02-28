#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require_relative "../lib/wavify"

OUTPUT_DIR = File.expand_path("../tmp/examples", __dir__)

def float_format
  Wavify::Core::Format.new(channels: 2, sample_rate: 44_100, bit_depth: 32, sample_format: :float)
end

def build_demo_recording
  format = float_format
  lead = Wavify::Audio.tone(frequency: 220.0, duration: 1.0, waveform: :sine, format: format).gain(-12)
  harmony = Wavify::Audio.tone(frequency: 330.0, duration: 1.0, waveform: :triangle, format: format).gain(-16)
  body = Wavify::Audio.mix(lead, harmony)

  noise = Wavify::Audio.tone(frequency: 1.0, duration: body.duration.total_seconds, waveform: :white_noise, format: format).gain(-30)
  signal = Wavify::Audio.mix(body, noise)

  head = Wavify::Audio.silence(0.15, format: format)
  tail = Wavify::Audio.silence(0.2, format: format)
  Wavify::Audio.new(head.buffer + signal.buffer + tail.buffer)
end

def process(audio)
  audio
    .trim(threshold: 0.02)
    .fade_in(0.01)
    .fade_out(0.08)
    .apply(Wavify::Effects::Compressor.new(threshold: -18, ratio: 3.5, attack: 0.005, release: 0.08))
    .apply(Wavify::Effects::Distortion.new(drive: 0.2, tone: 0.65, mix: 0.12))
    .normalize(target_db: -1.0)
end

def process_file(input_path, output_path)
  source = Wavify::Audio.read(input_path)
  processed = process(source)
  processed.convert(Wavify::Core::Format::CD_QUALITY).write(output_path)

  puts "Processed #{input_path} -> #{output_path}"
  puts "  source duration:    #{source.duration}"
  puts "  processed duration: #{processed.duration}"
  puts "  source peak:        #{source.peak_amplitude.round(4)}"
  puts "  output peak:        #{processed.peak_amplitude.round(4)}"
end

def run_demo
  FileUtils.mkdir_p(OUTPUT_DIR)
  source_path = File.join(OUTPUT_DIR, "audio_processing_source.wav")
  output_path = File.join(OUTPUT_DIR, "audio_processing_output.wav")

  source = build_demo_recording
  source.convert(Wavify::Core::Format::CD_QUALITY).write(source_path)
  process(source).convert(Wavify::Core::Format::CD_QUALITY).write(output_path)

  puts "Generated demo processing files:"
  puts "  #{source_path}"
  puts "  #{output_path}"
end

if ARGV.include?("-h") || ARGV.include?("--help")
  puts "Usage: ruby examples/audio_processing.rb [INPUT_PATH OUTPUT_PATH]"
  puts "When no args are given, a self-contained demo is written to tmp/examples/."
  exit(0)
end

if ARGV.length >= 2
  process_file(ARGV[0], ARGV[1])
else
  run_demo
end
