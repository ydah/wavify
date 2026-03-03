#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require_relative "../lib/wavify"

OUTPUT_DIR = File.expand_path("../tmp/examples", __dir__)
OUTPUT_PATH = File.join(OUTPUT_DIR, "cinematic_transition.wav")

def render_format
  Wavify::Core::Format.new(channels: 2, sample_rate: 48_000, bit_depth: 32, sample_format: :float)
end

def place(audio, at:, total_length:, format:)
  head = Wavify::Audio.silence(at, format: format)
  clip = Wavify::Audio.new(head.buffer + audio.buffer)
  remaining = total_length - clip.duration.total_seconds
  return clip if remaining <= 0.0

  Wavify::Audio.new(clip.buffer + Wavify::Audio.silence(remaining, format: format).buffer)
end

def drone_layer(frequency, duration, format)
  base = Wavify::Audio.tone(frequency: frequency, duration: duration, waveform: :triangle, format: format)
               .gain(-22)
               .fade_in(1.2)
               .fade_out(1.5)
  shimmer = Wavify::Audio.tone(frequency: frequency * 2.0, duration: duration, waveform: :sine, format: format)
                  .gain(-30)
                  .fade_in(1.5)
                  .fade_out(1.2)
  Wavify::Audio.mix(base, shimmer)
end

def riser(duration, format)
  steps = [220.0, 330.0, 440.0, 660.0, 880.0]
  segment = duration / steps.length
  layers = steps.map do |frequency|
    Wavify::Audio.tone(frequency: frequency, duration: segment, waveform: :sawtooth, format: format)
                 .gain(-24)
                 .fade_in(0.03)
                 .fade_out(0.04)
  end

  combined = layers.reduce { |memo, audio| Wavify::Audio.new(memo.buffer + audio.buffer) }
  noise = Wavify::Audio.tone(frequency: 1.0, duration: duration, waveform: :white_noise, format: format)
                .gain(-33)
                .fade_in(duration * 0.7)
                .fade_out(duration * 0.1)
                .apply(Wavify::DSP::Filter.highpass(cutoff: 2_500.0))
  Wavify::Audio.mix(combined, noise).apply(Wavify::Effects::Chorus.new(rate: 0.5, depth: 0.35, mix: 0.25))
end

def impact(format)
  low = Wavify::Audio.tone(frequency: 55.0, duration: 0.5, waveform: :sine, format: format)
              .gain(-10)
              .fade_out(0.45)
  noise = Wavify::Audio.tone(frequency: 1.0, duration: 0.38, waveform: :white_noise, format: format)
                .gain(-17)
                .apply(Wavify::DSP::Filter.bandpass(center: 1_600.0, bandwidth: 900.0))
                .fade_out(0.32)
  click = Wavify::Audio.tone(frequency: 2_000.0, duration: 0.02, waveform: :triangle, format: format)
                .gain(-20)
                .fade_out(0.015)

  Wavify::Audio.mix(low, noise, click)
               .apply(Wavify::Effects::Distortion.new(drive: 0.18, tone: 0.6, mix: 0.16))
               .normalize(target_db: -3.5)
end

def reverse_tail(format)
  source = Wavify::Audio.tone(frequency: 480.0, duration: 1.1, waveform: :triangle, format: format)
                 .gain(-28)
                 .apply(Wavify::Effects::Reverb.new(room_size: 0.72, damping: 0.48, mix: 0.44))
                 .fade_out(1.0)
  source.reverse.fade_in(0.6).fade_out(0.2)
end

def master(audio)
  audio
    .apply(Wavify::Effects::Compressor.new(threshold: -16, ratio: 3.2, attack: 0.004, release: 0.1))
    .apply(Wavify::Effects::Reverb.new(room_size: 0.45, damping: 0.5, mix: 0.18))
    .normalize(target_db: -1.0)
    .fade_in(0.08)
    .fade_out(1.2)
end

def build_scene
  format = render_format
  total_length = 12.0

  base_drone = Wavify::Audio.mix(
    drone_layer(110.0, total_length, format).pan(-0.15),
    drone_layer(146.83, total_length, format).pan(0.14)
  )
  pulse = Wavify::Audio.tone(frequency: 2.0, duration: 3.2, waveform: :sine, format: format)
                 .apply(Wavify::DSP::Filter.lowpass(cutoff: 180.0))
                 .gain(-31)
                 .fade_in(0.4)
                 .fade_out(0.5)
  build = place(riser(2.8, format), at: 6.2, total_length: total_length, format: format)
  hit = place(impact(format), at: 9.05, total_length: total_length, format: format)
  tail = place(reverse_tail(format), at: 8.15, total_length: total_length, format: format)
  pulse_layer = place(pulse, at: 4.9, total_length: total_length, format: format)

  Wavify::Audio.mix(base_drone, pulse_layer, build, tail, hit)
end

FileUtils.mkdir_p(OUTPUT_DIR)

raw = build_scene
final = master(raw).convert(Wavify::Core::Format::CD_QUALITY)
final.write(OUTPUT_PATH)

puts "Wrote #{OUTPUT_PATH}"
puts "  duration: #{final.duration}"
puts "  peak:     #{final.peak_amplitude.round(4)}"
puts "  rms:      #{final.rms_amplitude.round(4)}"
