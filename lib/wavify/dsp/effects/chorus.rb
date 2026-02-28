# frozen_string_literal: true

module Wavify
  module DSP
    module Effects
      # Modulated delay chorus effect.
      class Chorus < EffectBase
        def initialize(rate: 1.0, depth: 0.5, mix: 0.5)
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
          line = @delay_lines.fetch(channel)
          write_index = @write_indices.fetch(channel)

          mod_phase = @lfo_phase + channel_phase_offset(channel)
          mod = Math.sin(mod_phase)
          delay_samples = @base_delay_samples + (@depth_delay_samples * ((mod + 1.0) / 2.0))
          wet = read_fractional_delay(line, write_index, delay_samples)

          line[write_index] = dry
          @write_indices[channel] = (write_index + 1) % line.length
          advance_lfo!

          (dry * (1.0 - @mix)) + (wet * @mix)
        end

        private

        def prepare_runtime_state(sample_rate:, channels:)
          max_delay_seconds = 0.03
          @base_delay_samples = [(sample_rate * 0.012).round, 1].max
          @depth_delay_samples = (sample_rate * max_delay_seconds * @depth * 0.6).to_f
          line_length = [(@base_delay_samples + @depth_delay_samples.ceil + 3), 8].max

          @delay_lines = Array.new(channels) { Array.new(line_length, 0.0) }
          @write_indices = Array.new(channels, 0)
          @lfo_phase = 0.0
          @lfo_step = (2.0 * Math::PI * @rate) / (sample_rate * channels)
        end

        def reset_runtime_state
          @delay_lines = []
          @write_indices = []
          @base_delay_samples = nil
          @depth_delay_samples = nil
          @lfo_phase = 0.0
          @lfo_step = 0.0
        end

        def read_fractional_delay(line, write_index, delay_samples)
          integer = delay_samples.floor
          fraction = delay_samples - integer

          idx_a = (write_index - integer - 1) % line.length
          idx_b = (idx_a - 1) % line.length
          a = line[idx_a]
          b = line[idx_b]
          a + ((b - a) * fraction)
        end

        def channel_phase_offset(channel)
          return 0.0 if @runtime_channels.nil? || @runtime_channels <= 1

          (2.0 * Math::PI * channel) / @runtime_channels
        end

        def advance_lfo!
          @lfo_phase += @lfo_step
          @lfo_phase -= (2.0 * Math::PI) if @lfo_phase >= (2.0 * Math::PI)
        end

        def validate_positive!(value, name)
          raise InvalidParameterError, "#{name} must be a positive Numeric" unless value.is_a?(Numeric) && value.positive?

          value.to_f
        end

        def validate_unit!(value, name)
          raise InvalidParameterError, "#{name} must be Numeric in 0.0..1.0" unless value.is_a?(Numeric) && value.between?(0.0, 1.0)

          value.to_f
        end
      end
    end
  end
end
