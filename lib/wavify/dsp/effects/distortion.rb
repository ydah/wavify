# frozen_string_literal: true

module Wavify
  module DSP
    module Effects
      # Soft-clipping distortion with tone shaping and dry/wet mix.
      class Distortion < EffectBase
        def initialize(drive: 0.5, tone: 0.5, mix: 1.0)
          super()
          @drive = validate_unit!(drive, :drive)
          @tone = validate_unit!(tone, :tone)
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
          wet = Math.tanh(dry * pre_gain)

          # One-pole low-pass on the distorted signal for tone shaping.
          coeff = tone_coefficient(sample_rate)
          previous = @tone_state.fetch(channel)
          filtered = previous + (coeff * (wet - previous))
          @tone_state[channel] = filtered

          (dry * (1.0 - @mix)) + (filtered * @mix)
        end

        private

        def prepare_runtime_state(sample_rate:, channels:)
          @tone_state = Array.new(channels, 0.0)
        end

        def reset_runtime_state
          @tone_state = []
        end

        def pre_gain
          1.0 + (@drive * 19.0)
        end

        def tone_coefficient(sample_rate)
          cutoff = 500.0 + (@tone * 7_500.0)
          rc = 1.0 / (2.0 * Math::PI * cutoff)
          dt = 1.0 / sample_rate
          dt / (rc + dt)
        end

        def validate_unit!(value, name)
          raise InvalidParameterError, "#{name} must be Numeric in 0.0..1.0" unless value.is_a?(Numeric) && value.between?(0.0, 1.0)

          value.to_f
        end
      end
    end
  end
end
