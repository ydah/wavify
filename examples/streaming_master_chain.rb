#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require_relative "../lib/wavify"

OUTPUT_DIR = File.expand_path("../tmp/examples", __dir__)
DEMO_INPUT_PATH = File.join(OUTPUT_DIR, "streaming_master_chain_source.wav")
DEMO_OUTPUT_PATH = File.join(OUTPUT_DIR, "streaming_master_chain_output.aiff")

def render_format
  Wavify::Core::Format.new(channels: 2, sample_rate: 44_100, bit_depth: 32, sample_format: :float)
end

def usage
  puts <<~TEXT
    Usage:
      ruby examples/streaming_master_chain.rb [INPUT_PATH OUTPUT_PATH]

    When no arguments are given, a self-contained source file is generated and processed in tmp/examples/.
  TEXT
end

def build_source(path)
  format = render_format
  song = Wavify::DSL.build_definition(format: format, tempo: 108, default_bars: 8) do
    track :bass do
      synth :sawtooth
      notes "D2 . D2 . F2 . A2 . C2 . A1 . F1 . A1 .", resolution: 16
      envelope attack: 0.004, decay: 0.06, sustain: 0.35, release: 0.08
      gain(-12)
      pan(-0.15)
    end

    track :pad do
      synth :triangle
      chords %w[Dm9 Bbmaj7 Fmaj7 Cmaj7]
      envelope attack: 0.08, decay: 0.35, sustain: 0.72, release: 0.8
      gain(-16)
    end

    track :keys do
      synth :sine
      notes "F4 A4 C5 A4 D5 C5 A4 F4 E4 G4 A4 C5 D5 C5 A4 G4", resolution: 16
      envelope attack: 0.01, decay: 0.08, sustain: 0.55, release: 0.16
      effect :delay, time: 0.22, feedback: 0.28, mix: 0.21
      gain(-19)
      pan(0.18)
    end
  end

  song.validate!
  source = song.render
              .apply(Wavify::Effects::Reverb.new(room_size: 0.28, damping: 0.42, mix: 0.1))
              .normalize(target_db: -3.0)
  source.convert(Wavify::Core::Format::CD_QUALITY, dither: true, dither_seed: 0).write(path)
  source
end

def process_stream(input_path, output_path)
  metadata = Wavify::Audio.metadata(input_path)
  float_format = metadata.fetch(:format).with(sample_format: :float, bit_depth: 32)
  meter_readings = []
  progress_updates = []
  chain = Wavify::Audio.stream(input_path, chunk_size: 2_048)
                     .map_chunks(name: :float_workspace) { |chunk| chunk.convert(float_format) }
                     .meter { |stats| meter_readings << stats }
                     .progress(total_frames: metadata.fetch(:sample_frame_count)) { |stats| progress_updates << stats }
                     .pipe(
                       Wavify::Effects::Chorus.new(rate: 0.24, depth: 0.2, mix: 0.16),
                       name: :chorus
                     )
                     .pipe(
                       Wavify::Effects::Delay.new(time: 0.14, feedback: 0.18, mix: 0.1),
                       name: :delay
                     )
                     .pipe(Wavify::Effects::StereoWidener.new(width: 1.25), name: :stereo_width)
                     .pipe(
                       Wavify::Effects::MasteringChain.new(
                         highpass: 30.0,
                         presence: 1.0,
                         threshold: -18,
                         ratio: 2.6,
                         ceiling: -1.0
                       ),
                       name: :mastering
                     )

  chain.write_to(output_path, format: Wavify::Core::Format::CD_QUALITY)
  {
    chunks: meter_readings.length,
    peak: meter_readings.map { |stats| stats.fetch(:peak_amplitude) }.max || 0.0,
    processed_frames: progress_updates.last&.fetch(:sample_frame_count, 0) || 0,
    pipeline: chain.pipeline_steps.map { |step| step.fetch(:name) }
  }
end

if ARGV.include?("-h") || ARGV.include?("--help")
  usage
  exit(0)
end

FileUtils.mkdir_p(OUTPUT_DIR)
input_path = ARGV[0] || DEMO_INPUT_PATH
output_path = ARGV[1] || DEMO_OUTPUT_PATH

build_source(input_path) unless ARGV[0]
summary = process_stream(input_path, output_path)
source = Wavify::Audio.read(input_path)
rendered = Wavify::Audio.read(output_path)

puts "Processed #{input_path} -> #{output_path}"
puts "  source duration:  #{source.duration}"
puts "  output duration:  #{rendered.duration}"
puts "  chunks processed: #{summary.fetch(:chunks)}"
puts "  frames processed: #{summary.fetch(:processed_frames)}"
puts "  input peak seen:  #{summary.fetch(:peak).round(4)}"
puts "  output peak:      #{rendered.peak_amplitude.round(4)}"
puts "  pipeline:         #{summary.fetch(:pipeline).join(' -> ')}"
