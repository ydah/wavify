# frozen_string_literal: true

module Wavify
  module DSP
    module Effects
      # Speech-oriented cleanup preset for voice tracks.
      class PodcastChain < EffectChain
        # @param gate_threshold [Numeric] noise gate threshold in dBFS
        # @param highpass [Numeric, nil]
        # @param presence [Numeric, nil] peaking EQ gain in dB
        # @param compression_threshold [Numeric] compressor threshold in dBFS
        # @param ceiling [Numeric] limiter ceiling in dBFS
        def initialize(gate_threshold: -45.0, highpass: 80.0, presence: 3.0, compression_threshold: -20.0, ceiling: -1.0)
          super([
            NoiseGate.new(threshold: gate_threshold, floor: -80.0),
            EQ.simple(highpass: highpass, presence: presence_filter(presence)),
            Compressor.new(threshold: compression_threshold, ratio: 3.0, attack: 0.003, release: 0.12, makeup_gain: 2.0, knee: 4.0),
            Limiter.new(ceiling: ceiling)
          ])
        end

        private

        def presence_filter(gain_db)
          return nil unless gain_db

          { cutoff: 3_000.0, q: 0.9, gain_db: gain_db }
        end
      end
    end
  end
end
