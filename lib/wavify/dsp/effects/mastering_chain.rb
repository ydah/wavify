# frozen_string_literal: true

module Wavify
  module DSP
    module Effects
      # Small mastering-oriented preset chain.
      class MasteringChain < EffectChain
        # @param highpass [Numeric, nil]
        # @param presence [Numeric, nil] peaking EQ gain in dB
        # @param threshold [Numeric] compressor threshold in dBFS
        # @param ratio [Numeric] compressor ratio
        # @param ceiling [Numeric] limiter ceiling in dBFS
        def initialize(highpass: 30.0, presence: 1.5, threshold: -18.0, ratio: 2.0, ceiling: -1.0)
          super([
            EQ.simple(highpass: highpass, presence: presence_filter(presence)),
            Compressor.new(threshold: threshold, ratio: ratio, attack: 0.005, release: 0.08, makeup_gain: 1.5, knee: 6.0),
            Limiter.new(ceiling: ceiling)
          ])
        end

        private

        def presence_filter(gain_db)
          return nil unless gain_db

          { cutoff: 3_500.0, q: 0.8, gain_db: gain_db }
        end
      end
    end
  end
end
