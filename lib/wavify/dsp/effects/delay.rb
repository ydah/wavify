# frozen_string_literal: true

module Wavify
  module DSP
    module Effects
      # Simple feedback delay effect.
      class Delay < EffectBase
        def initialize(time: 0.3, feedback: 0.5, mix: 0.3)
          super()
          @time = validate_time!(time)
          @feedback = validate_ratio!(feedback, :feedback)
          @mix = validate_mix!(mix)
          reset
        end

        # Processes a single sample for one channel.
        #
        # @param sample [Numeric]
        # @param channel [Integer]
        # @param sample_rate [Integer]
        # @return [Float]
        def process_sample(sample, channel:, sample_rate:)
          line = @delay_lines.fetch(channel)
          index = @write_indices.fetch(channel)
          delayed = line[index]
          dry = sample.to_f
          wet = delayed

          output = (dry * (1.0 - @mix)) + (wet * @mix)
          line[index] = (dry + (wet * @feedback)).clamp(-1.0, 1.0)
          @write_indices[channel] = (index + 1) % line.length

          output
        end

        private

        def prepare_runtime_state(sample_rate:, channels:)
          delay_samples = [(sample_rate * @time).round, 1].max
          @delay_lines = Array.new(channels) { Array.new(delay_samples, 0.0) }
          @write_indices = Array.new(channels, 0)
        end

        def reset_runtime_state
          @delay_lines = []
          @write_indices = []
        end

        def validate_time!(value)
          raise InvalidParameterError, "time must be a positive Numeric" unless value.is_a?(Numeric) && value.positive?

          value.to_f
        end

        def validate_ratio!(value, name)
          raise InvalidParameterError, "#{name} must be in 0.0...1.0" unless value.is_a?(Numeric) && value >= 0.0 && value < 1.0

          value.to_f
        end

        def validate_mix!(value)
          raise InvalidParameterError, "mix must be Numeric in 0.0..1.0" unless value.is_a?(Numeric) && value.between?(0.0, 1.0)

          value.to_f
        end
      end
    end
  end
end
