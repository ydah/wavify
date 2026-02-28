#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require_relative "../lib/wavify"

OUTPUT_DIR = File.expand_path("../tmp/examples", __dir__)
OUTPUT_PATH = File.join(OUTPUT_DIR, "drum_machine.wav")

def render_format
  Wavify::Core::Format.new(channels: 2, sample_rate: 44_100, bit_depth: 32, sample_format: :float)
end

def build_song
  Wavify::DSL.build_definition(format: render_format, tempo: 116, default_bars: 2) do
    track :kick do
      synth :sine
      notes "C2 . . . C2 . . . C2 . . . C2 . . .", resolution: 16
      envelope attack: 0.001, decay: 0.05, sustain: 0.0, release: 0.06
      gain(-4)
      pan(-0.05)
    end

    track :snare do
      synth :white_noise
      notes ". . . . D2 . . . . . . . D2 . . .", resolution: 16
      envelope attack: 0.001, decay: 0.02, sustain: 0.0, release: 0.04
      gain(-14)
      pan(0.08)
    end

    track :hat do
      synth :white_noise
      notes "A4 A4 A4 A4 A4 A4 A4 A4 A4 A4 A4 A4 A4 A4 A4 A4", resolution: 16
      envelope attack: 0.001, decay: 0.005, sustain: 0.0, release: 0.01
      gain(-22)
      pan(0.2)
    end

    track :bass do
      synth :sawtooth
      notes "C2 . C2 . Eb2 . G2 . C2 . Bb1 . G1 . Bb1 .", resolution: 16
      envelope attack: 0.005, decay: 0.06, sustain: 0.35, release: 0.08
      gain(-13)
      pan(-0.15)
    end

    arrange do
      section :intro, bars: 1, tracks: %i[kick hat bass]
      section :groove, bars: 3, tracks: %i[kick snare hat bass]
    end
  end
end

def process_mix(audio)
  audio
    .apply(Wavify::Effects::Compressor.new(threshold: -14, ratio: 3.0, attack: 0.003, release: 0.08))
    .apply(Wavify::Effects::Reverb.new(room_size: 0.25, damping: 0.4, mix: 0.12))
    .normalize(target_db: -1.0)
end

FileUtils.mkdir_p(OUTPUT_DIR)

song = build_song
timeline = song.timeline
raw_mix = song.render
final_mix = process_mix(raw_mix).convert(Wavify::Core::Format::CD_QUALITY)
final_mix.write(OUTPUT_PATH)

puts "Wrote #{OUTPUT_PATH}"
puts "  duration: #{final_mix.duration}"
puts "  frames:   #{final_mix.sample_frame_count}"
puts "  events:   #{timeline.length}"
puts "  tracks:   #{song.tracks.map(&:name).join(', ')}"
