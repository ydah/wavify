# frozen_string_literal: true

module Wavify
  module DSP
    module Effects
      # Simple downward gate for suppressing low-level noise.
      class NoiseGate < EffectBase
        def initialize(threshold: -40.0, floor: -80.0)
          super()
          @threshold_db = validate_dbfs!(threshold, :threshold)
          @floor_db = validate_dbfs!(floor, :floor)
          @threshold = db_to_amplitude(@threshold_db)
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
          gain = value.abs < @threshold ? @floor_gain : 1.0
          value * gain
        end

        private

        def validate_dbfs!(value, name)
          unless value.is_a?(Numeric) && value.respond_to?(:finite?) && value.finite? && value <= 0.0
            raise InvalidParameterError, "#{name} must be a finite Numeric <= 0 dBFS"
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
