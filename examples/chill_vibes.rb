#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require_relative "../lib/wavify"

OUTPUT_DIR = File.expand_path("../tmp/examples", __dir__)
SAMPLE_DIR = File.join(OUTPUT_DIR, "chill_vibes_samples")
OUTPUT_PATH = File.join(OUTPUT_DIR, "chill_vibes.wav")

def render_format
  Wavify::Core::Format.new(channels: 2, sample_rate: 48_000, bit_depth: 32, sample_format: :float)
end

def place(audio, at:, format:)
  head = Wavify::Audio.silence(at, format: format)
  Wavify::Audio.new(head.buffer + audio.buffer)
end

def kick_sample(format)
  body = Wavify::Audio.tone(frequency: 50.0, duration: 0.2, waveform: :sine, format: format)
                     .fade_out(0.17)
  thump = Wavify::Audio.tone(frequency: 110.0, duration: 0.05, waveform: :triangle, format: format)
                      .gain(-15)
                      .fade_out(0.04)
  click = Wavify::Audio.tone(frequency: 1.0, duration: 0.02, waveform: :white_noise, format: format)
                      .gain(-26)
                      .apply(Wavify::DSP::Filter.highpass(cutoff: 3_000.0))
                      .fade_out(0.017)
  Wavify::Audio.mix(body, thump, click).normalize(target_db: -5.0)
end

def snare_sample(format)
  noise = Wavify::Audio.tone(frequency: 1.0, duration: 0.14, waveform: :white_noise, format: format)
                      .gain(-14)
                      .apply(Wavify::DSP::Filter.bandpass(center: 2_000.0, bandwidth: 1_400.0))
                      .fade_out(0.12)
  tone = Wavify::Audio.tone(frequency: 190.0, duration: 0.11, waveform: :triangle, format: format)
                     .gain(-21)
                     .fade_out(0.09)
  Wavify::Audio.mix(noise, tone).normalize(target_db: -8.0)
end

def hat_sample(format)
  Wavify::Audio.tone(frequency: 1.0, duration: 0.06, waveform: :white_noise, format: format)
               .gain(-21)
               .apply(Wavify::DSP::Filter.highpass(cutoff: 7_000.0))
               .fade_out(0.05)
               .normalize(target_db: -11.0)
end

def shaker_sample(format)
  burst = Wavify::Audio.tone(frequency: 1.0, duration: 0.09, waveform: :white_noise, format: format)
                       .gain(-25)
                       .apply(Wavify::DSP::Filter.bandpass(center: 5_200.0, bandwidth: 3_000.0))
                       .fade_out(0.08)
  Wavify::Audio.mix(
    place(burst, at: 0.0, format: format),
    place(burst.gain(-3), at: 0.02, format: format)
  ).normalize(target_db: -12.0)
end

def write_drum_samples(format)
  FileUtils.mkdir_p(SAMPLE_DIR)
  paths = {
    kick: File.join(SAMPLE_DIR, "kick.wav"),
    snare: File.join(SAMPLE_DIR, "snare.wav"),
    hat: File.join(SAMPLE_DIR, "hat.wav"),
    shaker: File.join(SAMPLE_DIR, "shaker.wav")
  }

  kick_sample(format).convert(Wavify::Core::Format::CD_QUALITY).write(paths.fetch(:kick))
  snare_sample(format).convert(Wavify::Core::Format::CD_QUALITY).write(paths.fetch(:snare))
  hat_sample(format).convert(Wavify::Core::Format::CD_QUALITY).write(paths.fetch(:hat))
  shaker_sample(format).convert(Wavify::Core::Format::CD_QUALITY).write(paths.fetch(:shaker))
  paths
end

def build_song(format:, sample_paths:)
  Wavify::DSL.build_definition(format: format, tempo: 88, beats_per_bar: 4, default_bars: 2) do
    track :drums do
      sample :kick, sample_paths.fetch(:kick)
      sample :snare, sample_paths.fetch(:snare)
      sample :hat, sample_paths.fetch(:hat)
      sample :shaker, sample_paths.fetch(:shaker)
      pattern :kick, "X...x...X...x..."
      pattern :snare, "....x.......x..."
      pattern :hat, "x.x.x.x.x.x.x.x."
      pattern :shaker, "..x...x...x...x."
      effect :compressor, threshold: -22, ratio: 2.0, attack: 0.003, release: 0.08
      effect :reverb, room_size: 0.28, damping: 0.45, mix: 0.09
      gain(-7)
    end

    track :bass do
      synth :sine
      notes "C2 . G1 . Bb1 . F1 . C2 . G1 . Bb1 . G1 .", resolution: 16
      envelope attack: 0.01, decay: 0.14, sustain: 0.5, release: 0.14
      effect :compressor, threshold: -19, ratio: 2.4, attack: 0.006, release: 0.1
      gain(-16)
      pan(-0.06)
    end

    track :keys do
      synth :triangle
      chords %w[Cm9 Gm9 Bbmaj7 Fsus2]
      envelope attack: 0.22, decay: 0.5, sustain: 0.7, release: 0.95
      effect :chorus, rate: 0.24, depth: 0.42, mix: 0.3
      effect :reverb, room_size: 0.6, damping: 0.5, mix: 0.22
      gain(-17)
      pan(0.08)
    end

    track :topline do
      synth :sine
      notes "G4 Bb4 C5 Bb4 G4 . F4 G4 Bb4 C5 D5 C5 Bb4 G4 .", resolution: 16
      envelope attack: 0.02, decay: 0.15, sustain: 0.48, release: 0.2
      effect :delay, time: 0.32, feedback: 0.28, mix: 0.24
      gain(-22)
      pan(0.24)
    end

    arrange do
      section :intro, bars: 2, tracks: %i[drums keys]
      section :groove, bars: 4, tracks: %i[drums bass keys]
      section :lift, bars: 2, tracks: %i[drums bass keys topline]
      section :breakdown, bars: 2, tracks: %i[keys topline]
      section :outro, bars: 2, tracks: %i[drums bass keys]
    end
  end
end

def master(audio)
  audio
    .apply(Wavify::Effects::Compressor.new(threshold: -17, ratio: 2.4, attack: 0.004, release: 0.11))
    .apply(Wavify::Effects::Reverb.new(room_size: 0.42, damping: 0.53, mix: 0.14))
    .apply(Wavify::Effects::Chorus.new(rate: 0.2, depth: 0.2, mix: 0.08))
    .normalize(target_db: -1.0)
    .fade_in(0.2)
    .fade_out(1.0)
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
final = master(raw).convert(Wavify::Core::Format::CD_QUALITY)
final.write(OUTPUT_PATH)

puts "Wrote #{OUTPUT_PATH}"
puts "  duration: #{final.duration}"
puts "  peak:     #{final.peak_amplitude.round(4)}"
puts "  rms:      #{final.rms_amplitude.round(4)}"
print_timeline_summary(timeline)
