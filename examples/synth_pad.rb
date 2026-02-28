#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require_relative "../lib/wavify"

OUTPUT_DIR = File.expand_path("../tmp/examples", __dir__)
OUTPUT_PATH = File.join(OUTPUT_DIR, "synth_pad.wav")

format = Wavify::Core::Format.new(channels: 2, sample_rate: 48_000, bit_depth: 32, sample_format: :float)

audio = Wavify.build(nil, format: format, tempo: 72, default_bars: 4) do
  track :pad do
    synth :triangle
    chords %w[Cm9 Abmaj7 Ebmaj7 Bbsus2]
    envelope attack: 0.25, decay: 0.5, sustain: 0.75, release: 0.9
    gain(-12)
  end

  track :lead do
    synth :sine
    notes "G4 Bb4 C5 D5 Eb5 D5 C5 Bb4", resolution: 8
    envelope attack: 0.02, decay: 0.1, sustain: 0.6, release: 0.25
    gain(-18)
    pan(0.1)
  end
end

processed = audio
            .apply(Wavify::Effects::Chorus.new(rate: 0.3, depth: 0.45, mix: 0.35))
            .apply(Wavify::Effects::Reverb.new(room_size: 0.7, damping: 0.5, mix: 0.25))
            .fade_in(0.2)
            .fade_out(0.6)
            .normalize(target_db: -1.0)

FileUtils.mkdir_p(OUTPUT_DIR)
processed.convert(Wavify::Core::Format::CD_QUALITY).write(OUTPUT_PATH)

puts "Wrote #{OUTPUT_PATH}"
puts "  duration: #{processed.duration}"
puts "  peak:     #{processed.peak_amplitude.round(4)}"
puts "  rms:      #{processed.rms_amplitude.round(4)}"
