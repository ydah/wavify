#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "benchmark_helper"

helper = WavifyBenchmarks::Helper
iterations = helper.int_env("DSP_BENCH_ITERATIONS", 8)
duration_seconds = helper.float_env("DSP_BENCH_DURATION", 2.0)
format = helper.float_stereo_format
audio = helper.demo_audio(duration_seconds: duration_seconds, format: format)
buffer = audio.buffer

helper.banner("DSP effects benchmark")
helper.print_config(
  iterations: iterations,
  duration_seconds: duration_seconds,
  sample_rate: buffer.format.sample_rate,
  channels: buffer.format.channels,
  frames: buffer.sample_frame_count
)

effects = {
  delay: -> { Wavify::Effects::Delay.new(time: 0.18, feedback: 0.35, mix: 0.25) },
  reverb: -> { Wavify::Effects::Reverb.new(room_size: 0.6, damping: 0.4, mix: 0.2) },
  chorus: -> { Wavify::Effects::Chorus.new(rate: 0.8, depth: 0.35, mix: 0.3) },
  distortion: -> { Wavify::Effects::Distortion.new(drive: 0.45, tone: 0.6, mix: 0.4) },
  compressor: -> { Wavify::Effects::Compressor.new(threshold: -16, ratio: 3.0, attack: 0.005, release: 0.1) }
}.freeze

effects.each do |name, factory|
  helper.measure("#{name} x#{iterations}") do
    iterations.times do
      effect = factory.call
      effect.process(buffer)
    end
  end
end

helper.measure("audio chain x#{iterations}") do
  iterations.times do
    audio
      .apply(Wavify::Effects::Compressor.new(threshold: -16, ratio: 2.5, attack: 0.005, release: 0.08))
      .apply(Wavify::Effects::Chorus.new(rate: 0.7, depth: 0.2, mix: 0.2))
      .apply(Wavify::Effects::Reverb.new(room_size: 0.4, damping: 0.5, mix: 0.15))
  end
end
