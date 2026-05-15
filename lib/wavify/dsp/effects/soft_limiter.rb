# frozen_string_literal: true

module Wavify
  module DSP
    module Effects
      # Soft-knee peak limiter for taming overs without a hard flat top.
      class SoftLimiter < EffectBase
        def initialize(threshold: 0.8, ceiling: 1.0, drive: 1.0)
          super()
          @threshold = validate_unit!(threshold, :threshold)
          @ceiling = validate_unit!(ceiling, :ceiling)
          raise InvalidParameterError, "ceiling must be greater than threshold" unless @ceiling > @threshold

          @drive = validate_positive!(drive, :drive)
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
          return value if magnitude <= @threshold

          range = @ceiling - @threshold
          sign = value.negative? ? -1.0 : 1.0
          limited = @threshold + (range * (1.0 - Math.exp(-((magnitude - @threshold) * @drive) / range)))
          sign * limited.clamp(@threshold, @ceiling)
        end

        private

        def validate_unit!(value, name)
          unless value.is_a?(Numeric) && value.respond_to?(:finite?) && value.finite? && value.between?(0.0, 1.0)
            raise InvalidParameterError, "#{name} must be a finite Numeric in 0.0..1.0"
          end

          value.to_f
        end

        def validate_positive!(value, name)
          unless value.is_a?(Numeric) && value.respond_to?(:finite?) && value.finite? && value.positive?
            raise InvalidParameterError, "#{name} must be a positive finite Numeric"
          end

          value.to_f
        end
      end
    end
  end
end
