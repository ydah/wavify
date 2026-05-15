# frozen_string_literal: true

module Wavify
  module DSP
    module Effects
      # Hard peak limiter with input gain and dBFS ceiling controls.
      class Limiter < EffectBase
        def initialize(ceiling: -1.0, input_gain: 0.0)
          super()
          @ceiling_db = validate_dbfs!(ceiling, :ceiling)
          @input_gain_db = validate_finite_numeric!(input_gain, :input_gain).to_f
          @ceiling = db_to_amplitude(@ceiling_db)
          @input_gain = db_to_amplitude(@input_gain_db)
          reset
        end

        # Processes a single sample for one channel.
        #
        # @param sample [Numeric]
        # @param channel [Integer]
        # @param sample_rate [Integer]
        # @return [Float]
        def process_sample(sample, channel:, sample_rate:)
          (sample.to_f * @input_gain).clamp(-@ceiling, @ceiling)
        end

        private

        def validate_dbfs!(value, name)
          numeric = validate_finite_numeric!(value, name)
          raise InvalidParameterError, "#{name} must be <= 0 dBFS" if numeric.positive?

          numeric.to_f
        end

        def validate_finite_numeric!(value, name)
          unless value.is_a?(Numeric) && value.respond_to?(:finite?) && value.finite?
            raise InvalidParameterError, "#{name} must be a finite Numeric"
          end

          value
        end

        def db_to_amplitude(db)
          10.0**(db / 20.0)
        end
      end
    end
  end
end
