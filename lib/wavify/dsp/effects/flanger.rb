# frozen_string_literal: true

module Wavify
  module DSP
    module Effects
      # Short modulated comb delay effect.
      class Flanger < EffectBase
        MAX_DELAY_SECONDS = 0.006
        TAIL_AMPLITUDE = 1.0e-6

        def initialize(rate: 0.5, depth: 0.7, feedback: 0.35, mix: 0.5)
          super()
          @rate = validate_positive!(rate, :rate)
          @depth = validate_unit!(depth, :depth)
          @feedback = validate_feedback!(feedback)
          @mix = validate_unit!(mix, :mix)
          reset
        end

        def process_sample(sample, channel:, sample_rate:)
          dry = sample.to_f
          line = @delay_lines.fetch(channel)
          write_index = @write_indices.fetch(channel)

          mod = @lfo.value_at(channel_phase_offset(channel))
          delay_samples = @base_delay_samples + (@depth_delay_samples * ((mod + 1.0) / 2.0))
          wet = read_fractional_delay(line, write_index, delay_samples)

          line[write_index] = dry + (wet * @feedback)
          @write_indices[channel] = (write_index + 1) % line.length
          @lfo.next_value if channel == (@runtime_channels - 1)

          (dry * (1.0 - @mix)) + (wet * @mix)
        end

        def tail_duration
          return 0.0 if @mix.zero?

          repetitions = if @feedback.zero?
                          1
                        else
                          (Math.log(TAIL_AMPLITUDE) / Math.log(@feedback.abs)).ceil
                        end
          MAX_DELAY_SECONDS * [repetitions, 1].max
        end

        def latency
          @mix >= 1.0 ? MAX_DELAY_SECONDS : 0.0
        end

        private

        def prepare_runtime_state(sample_rate:, channels:)
          @base_delay_samples = [(sample_rate * 0.0015).round, 1].max
          @depth_delay_samples = (sample_rate * (MAX_DELAY_SECONDS - 0.0015) * @depth).to_f
          line_length = [(@base_delay_samples + @depth_delay_samples.ceil + 3), 8].max
          @delay_lines = Array.new(channels) { Array.new(line_length, 0.0) }
          @write_indices = Array.new(channels, 0)
          @lfo = DSP::LFO.new(rate: @rate, sample_rate: sample_rate)
        end

        def reset_runtime_state
          @delay_lines = []
          @write_indices = []
          @base_delay_samples = nil
          @depth_delay_samples = nil
          @lfo = nil
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

          channel.to_f / @runtime_channels
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

        def validate_feedback!(value)
          unless value.is_a?(Numeric) && value.respond_to?(:finite?) && value.finite? && value.between?(-0.95, 0.95)
            raise InvalidParameterError, "feedback must be a finite Numeric in -0.95..0.95"
          end

          value.to_f
        end
      end
    end
  end
end
