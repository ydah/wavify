# frozen_string_literal: true

module Wavify
  module DSP
    module Effects
      # Downward expander that reduces low-level material below a threshold.
      class Expander < EffectBase
        def initialize(threshold: -40.0, ratio: 2.0, floor: -80.0)
          super()
          @threshold_db = validate_dbfs!(threshold, :threshold)
          @ratio = validate_ratio!(ratio)
          @floor_db = validate_dbfs!(floor, :floor)
          @floor_gain = db_to_amplitude(@floor_db)
          reset
        end

        # Processes a single sample for one channel.
        #
        # @param sample [Numeric]
        # @param channel [Integer]
        # @param sample_rate [Integer]
        # @return [Float]
        def process_sample(sample, channel:, sample_rate:)
          value = sample.to_f
          magnitude = value.abs
          return value if magnitude.zero?

          input_db = 20.0 * Math.log10(magnitude)
          return value if input_db >= @threshold_db

          gain_reduction_db = (@threshold_db - input_db) * (@ratio - 1.0)
          gain = [db_to_amplitude(-gain_reduction_db), @floor_gain].max
          value * gain
        end

        private

        def validate_dbfs!(value, name)
          unless value.is_a?(Numeric) && value.respond_to?(:finite?) && value.finite? && value <= 0.0
            raise InvalidParameterError, "#{name} must be a finite Numeric <= 0 dBFS"
          end

          value.to_f
        end

        def validate_ratio!(value)
          unless value.is_a?(Numeric) && value.respond_to?(:finite?) && value.finite? && value >= 1.0
            raise InvalidParameterError, "ratio must be a finite Numeric >= 1.0"
          end

          value.to_f
        end

        def db_to_amplitude(db)
          10.0**(db / 20.0)
        end
      end
    end
  end
end
