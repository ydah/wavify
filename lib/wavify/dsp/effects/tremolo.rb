# frozen_string_literal: true

module Wavify
  module DSP
    module Effects
      # Amplitude modulation effect using a sine LFO.
      class Tremolo < EffectBase
        def initialize(rate: 5.0, depth: 0.5, mix: 1.0)
          super()
          @rate = validate_positive!(rate, :rate)
          @depth = validate_unit!(depth, :depth)
          @mix = validate_unit!(mix, :mix)
          reset
        end

        # Processes a single sample for one channel.
        #
        # @param sample [Numeric]
        # @param channel [Integer]
        # @param sample_rate [Integer]
        # @return [Float]
        def process_sample(sample, channel:, sample_rate:)
          dry = sample.to_f
          mod = 1.0 - (@depth * ((Math.sin(@phase) + 1.0) / 2.0))
          wet = dry * mod
          advance_phase! if channel == (@runtime_channels - 1)

          (dry * (1.0 - @mix)) + (wet * @mix)
        end

        private

        def prepare_runtime_state(sample_rate:, channels:)
          @phase = 0.0
          @phase_step = (2.0 * Math::PI * @rate) / sample_rate
        end

        def reset_runtime_state
          @phase = 0.0
          @phase_step = 0.0
        end

        def advance_phase!
          @phase += @phase_step
          @phase -= (2.0 * Math::PI) while @phase >= (2.0 * Math::PI)
        end

        def validate_positive!(value, name)
          unless value.is_a?(Numeric) && value.respond_to?(:finite?) && value.finite? && value.positive?
            raise InvalidParameterError, "#{name} must be a positive finite Numeric"
          end

          value.to_f
        end

        def validate_unit!(value, name)
          unless value.is_a?(Numeric) && value.respond_to?(:finite?) && value.finite? && value.between?(0.0, 1.0)
            raise InvalidParameterError, "#{name} must be a finite Numeric in 0.0..1.0"
          end

          value.to_f
        end
      end
    end
  end
end
