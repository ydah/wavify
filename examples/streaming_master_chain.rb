#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require_relative "../lib/wavify"

OUTPUT_DIR = File.expand_path("../tmp/examples", __dir__)
DEMO_INPUT_PATH = File.join(OUTPUT_DIR, "streaming_master_chain_source.wav")
DEMO_OUTPUT_PATH = File.join(OUTPUT_DIR, "streaming_master_chain_output.aiff")

class ChunkMeter
  attr_reader :chunks, :peak

  def initialize
    @chunks = 0
    @peak = 0.0
  end

  def call(buffer)
    @chunks += 1
    float = buffer.convert(buffer.format.with(sample_format: :float, bit_depth: 32))
    chunk_peak = float.samples.map(&:abs).max || 0.0
    @peak = chunk_peak if chunk_peak > @peak
    buffer
  end
end

class StereoWidthProcessor
  def initialize(width: 1.2)
    @width = width.to_f
  end

  def call(buffer)
    return buffer unless buffer.format.channels == 2

    float_format = buffer.format.with(sample_format: :float, bit_depth: 32)
    float = buffer.convert(float_format)
    widened = float.samples.each_slice(2).flat_map do |left, right|
      mid = (left + right) * 0.5
      side = ((left - right) * 0.5) * @width
      [(mid + side).clamp(-1.0, 1.0), (mid - side).clamp(-1.0, 1.0)]
    end
    Wavify::Core::SampleBuffer.new(widened, float_format).convert(buffer.format)
  end
end

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

  source = song.render
              .apply(Wavify::Effects::Reverb.new(room_size: 0.28, damping: 0.42, mix: 0.1))
              .normalize(target_db: -3.0)
  source.convert(Wavify::Core::Format::CD_QUALITY).write(path)
  source
end

def process_stream(input_path, output_path)
  meter = ChunkMeter.new
  highpass = Wavify::DSP::Filter.highpass(cutoff: 120.0)
  chain = Wavify::Audio.stream(input_path, chunk_size: 2_048)
                     .pipe(meter)
                     .pipe(->(chunk) { highpass.apply(chunk) })
                     .pipe(Wavify::Effects::Compressor.new(threshold: -18, ratio: 2.6, attack: 0.006, release: 0.12))
                     .pipe(StereoWidthProcessor.new(width: 1.25))
                     .pipe(Wavify::Effects::Chorus.new(rate: 0.24, depth: 0.2, mix: 0.16))
                     .pipe(Wavify::Effects::Delay.new(time: 0.14, feedback: 0.18, mix: 0.1))

  chain.write_to(output_path, format: Wavify::Core::Format::CD_QUALITY)
  meter
end

if ARGV.include?("-h") || ARGV.include?("--help")
  usage
  exit(0)
end

FileUtils.mkdir_p(OUTPUT_DIR)
input_path = ARGV[0] || DEMO_INPUT_PATH
output_path = ARGV[1] || DEMO_OUTPUT_PATH

build_source(input_path) unless ARGV[0]
meter = process_stream(input_path, output_path)
source = Wavify::Audio.read(input_path)
rendered = Wavify::Audio.read(output_path)

puts "Processed #{input_path} -> #{output_path}"
puts "  source duration:  #{source.duration}"
puts "  output duration:  #{rendered.duration}"
puts "  chunks processed: #{meter.chunks}"
puts "  input peak seen:  #{meter.peak.round(4)}"
puts "  output peak:      #{rendered.peak_amplitude.round(4)}"
