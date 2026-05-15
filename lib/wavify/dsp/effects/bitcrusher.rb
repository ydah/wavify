# frozen_string_literal: true

module Wavify
  module DSP
    module Effects
      # Bit-depth reduction and sample-rate hold effect.
      class Bitcrusher < EffectBase
        def initialize(bit_depth: 8, downsample: 1, mix: 1.0)
          super()
          @bit_depth = validate_bit_depth!(bit_depth)
          @downsample = validate_downsample!(downsample)
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
          if (@counters.fetch(channel) % @downsample).zero?
            @held_samples[channel] = quantize(dry)
          end
          @counters[channel] += 1

          wet = @held_samples.fetch(channel)
          (dry * (1.0 - @mix)) + (wet * @mix)
        end

        private

        def prepare_runtime_state(sample_rate:, channels:)
          @held_samples = Array.new(channels, 0.0)
          @counters = Array.new(channels, 0)
          @quantization_steps = (2**@bit_depth) - 1
        end

        def reset_runtime_state
          @held_samples = []
          @counters = []
          @quantization_steps = nil
        end

        def quantize(value)
          normalized = ((value.clamp(-1.0, 1.0) + 1.0) / 2.0)
          ((normalized * @quantization_steps).round / @quantization_steps.to_f * 2.0) - 1.0
        end

        def validate_bit_depth!(value)
          raise InvalidParameterError, "bit_depth must be an Integer in 1..24" unless value.is_a?(Integer) && value.between?(1, 24)

          value
        end

        def validate_downsample!(value)
          raise InvalidParameterError, "downsample must be a positive Integer" unless value.is_a?(Integer) && value.positive?

          value
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
