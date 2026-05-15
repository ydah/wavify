# frozen_string_literal: true

module Wavify
  module DSP
    module Effects
      # Stereo sine-LFO auto-panner.
      class AutoPan < EffectBase
        def initialize(rate: 0.5, depth: 1.0)
          super()
          @rate = validate_positive!(rate, :rate)
          @depth = validate_unit!(depth, :depth)
          reset
        end

        # Processes a single sample for one stereo channel.
        #
        # @param sample [Numeric]
        # @param channel [Integer]
        # @param sample_rate [Integer]
        # @return [Float]
        def process_sample(sample, channel:, sample_rate:)
          raise InvalidParameterError, "AutoPan requires stereo input" unless @runtime_channels == 2

          position = Math.sin(@phase) * @depth
          left_gain, right_gain = constant_power_pan_gains(position)
          output = sample.to_f * (channel.zero? ? left_gain : right_gain)
          advance_phase! if channel == 1
          output
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

        def constant_power_pan_gains(position)
          angle = (position + 1.0) * (Math::PI / 4.0)
          [Math.cos(angle), Math.sin(angle)]
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
