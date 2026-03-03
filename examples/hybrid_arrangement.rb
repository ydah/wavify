#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require_relative "../lib/wavify"

OUTPUT_DIR = File.expand_path("../tmp/examples", __dir__)
SAMPLE_DIR = File.join(OUTPUT_DIR, "hybrid_arrangement_samples")
RAW_OUTPUT_PATH = File.join(OUTPUT_DIR, "hybrid_arrangement_raw.wav")
MASTER_OUTPUT_PATH = File.join(OUTPUT_DIR, "hybrid_arrangement_master.wav")

def render_format
  Wavify::Core::Format.new(channels: 2, sample_rate: 44_100, bit_depth: 32, sample_format: :float)
end

def place(audio, at:, format:)
  head = Wavify::Audio.silence(at, format: format)
  Wavify::Audio.new(head.buffer + audio.buffer)
end

def kick_sample(format)
  body = Wavify::Audio.tone(frequency: 52.0, duration: 0.18, waveform: :sine, format: format)
                     .fade_out(0.16)
  click = Wavify::Audio.tone(frequency: 2_100.0, duration: 0.015, waveform: :triangle, format: format)
                      .gain(-22)
                      .fade_out(0.012)
  Wavify::Audio.mix(body, click).normalize(target_db: -4.0)
end

def snare_sample(format)
  noise = Wavify::Audio.tone(frequency: 1.0, duration: 0.15, waveform: :white_noise, format: format)
                      .gain(-11)
                      .fade_out(0.12)
  tone = Wavify::Audio.tone(frequency: 185.0, duration: 0.11, waveform: :triangle, format: format)
                     .gain(-19)
                     .fade_out(0.09)
  Wavify::Audio.mix(noise, tone)
               .apply(Wavify::DSP::Filter.highpass(cutoff: 380.0))
               .normalize(target_db: -7.0)
end

def hat_sample(format)
  Wavify::Audio.tone(frequency: 1.0, duration: 0.07, waveform: :white_noise, format: format)
               .gain(-20)
               .apply(Wavify::DSP::Filter.highpass(cutoff: 6_200.0))
               .fade_out(0.06)
               .normalize(target_db: -10.0)
end

def clap_sample(format)
  base = Wavify::Audio.tone(frequency: 1.0, duration: 0.11, waveform: :white_noise, format: format)
                     .gain(-15)
                     .apply(Wavify::DSP::Filter.bandpass(center: 2_400.0, bandwidth: 1_200.0))
                     .fade_out(0.1)
  Wavify::Audio.mix(
    place(base, at: 0.0, format: format),
    place(base.gain(-3), at: 0.016, format: format),
    place(base.gain(-6), at: 0.032, format: format)
  ).normalize(target_db: -9.0)
end

def write_drum_samples(format)
  FileUtils.mkdir_p(SAMPLE_DIR)
  paths = {
    kick: File.join(SAMPLE_DIR, "kick.wav"),
    snare: File.join(SAMPLE_DIR, "snare.wav"),
    hat: File.join(SAMPLE_DIR, "hat.wav"),
    clap: File.join(SAMPLE_DIR, "clap.wav")
  }

  kick_sample(format).convert(Wavify::Core::Format::CD_QUALITY).write(paths.fetch(:kick))
  snare_sample(format).convert(Wavify::Core::Format::CD_QUALITY).write(paths.fetch(:snare))
  hat_sample(format).convert(Wavify::Core::Format::CD_QUALITY).write(paths.fetch(:hat))
  clap_sample(format).convert(Wavify::Core::Format::CD_QUALITY).write(paths.fetch(:clap))
  paths
end

def build_song(format:, sample_paths:)
  Wavify::DSL.build_definition(format: format, tempo: 126, beats_per_bar: 4, default_bars: 2) do
    track :drums do
      sample :kick, sample_paths.fetch(:kick)
      sample :snare, sample_paths.fetch(:snare)
      sample :hat, sample_paths.fetch(:hat)
      sample :clap, sample_paths.fetch(:clap)
      pattern :kick, "X...x...X...x..."
      pattern :snare, "....x.......x..."
      pattern :hat, "x.x.x.x.x.x.x.x."
      pattern :clap, "........x......."
      effect :compressor, threshold: -20, ratio: 2.2, attack: 0.002, release: 0.06
      gain(-4)
      pan(-0.03)
    end

    track :bass do
      synth :sawtooth
      notes "A1 . A1 . C2 . E2 . A1 . G1 . E1 . G1 .", resolution: 16
      envelope attack: 0.003, decay: 0.07, sustain: 0.36, release: 0.08
      effect :distortion, drive: 0.12, tone: 0.55, mix: 0.12
      gain(-14)
      pan(-0.2)
    end

    track :chords do
      synth :triangle
      chords %w[Am9 Fmaj7 Cmaj7 Gsus2]
      envelope attack: 0.15, decay: 0.4, sustain: 0.72, release: 0.8
      effect :chorus, rate: 0.28, depth: 0.45, mix: 0.3
      gain(-18)
      pan(0.1)
    end

    track :lead do
      synth :sine
      notes "E5 G5 A5 C6 A5 G5 E5 D5", resolution: 8
      envelope attack: 0.01, decay: 0.08, sustain: 0.55, release: 0.18
      effect :delay, time: 0.19, feedback: 0.32, mix: 0.23
      gain(-20)
      pan(0.22)
    end

    arrange do
      section :intro, bars: 1, tracks: %i[drums chords]
      section :verse, bars: 2, tracks: %i[drums bass chords]
      section :lift, bars: 1, tracks: %i[drums bass chords lead]
      section :breakdown, bars: 1, tracks: %i[chords lead]
      section :finale, bars: 2, tracks: %i[drums bass chords lead]
    end
  end
end

def master(audio)
  audio
    .apply(Wavify::Effects::Compressor.new(threshold: -15, ratio: 3.0, attack: 0.004, release: 0.09))
    .apply(Wavify::Effects::Reverb.new(room_size: 0.35, damping: 0.45, mix: 0.12))
    .normalize(target_db: -1.0)
    .fade_in(0.04)
    .fade_out(0.45)
end

def print_timeline_summary(timeline)
  by_track = timeline.group_by { |event| event.fetch(:track) }
  puts "Timeline summary:"
  by_track.sort_by { |name, _| name.to_s }.each do |name, events|
    puts "  #{name}: #{events.length} events"
  end
end

FileUtils.mkdir_p(OUTPUT_DIR)
format = render_format
sample_paths = write_drum_samples(format)
song = build_song(format: format, sample_paths: sample_paths)

timeline = song.timeline
raw = song.render
mastered = master(raw).convert(Wavify::Core::Format::CD_QUALITY)

raw.convert(Wavify::Core::Format::CD_QUALITY).write(RAW_OUTPUT_PATH)
mastered.write(MASTER_OUTPUT_PATH)

puts "Wrote #{RAW_OUTPUT_PATH}"
puts "Wrote #{MASTER_OUTPUT_PATH}"
puts "  duration: #{mastered.duration}"
puts "  peak:     #{mastered.peak_amplitude.round(4)}"
puts "  rms:      #{mastered.rms_amplitude.round(4)}"
print_timeline_summary(timeline)
