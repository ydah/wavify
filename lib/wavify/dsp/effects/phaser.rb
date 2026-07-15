# frozen_string_literal: true

module Wavify
  module DSP
    module Effects
      # Modulated all-pass phase shifting effect.
      class Phaser < EffectBase
        MAX_STAGES = 32
        TAIL_AMPLITUDE = 1.0e-6
        MAX_ALLPASS_COEFFICIENT = 0.9
        REFERENCE_SAMPLE_RATE = 44_100.0

        def initialize(rate: 0.5, depth: 0.7, feedback: 0.2, mix: 0.5, stages: 4)
          super()
          @rate = validate_positive!(rate, :rate)
          @depth = validate_unit!(depth, :depth)
          @feedback = validate_feedback!(feedback)
          @mix = validate_unit!(mix, :mix)
          @stages = validate_stages!(stages)
          reset
        end

        def process_sample(sample, channel:, sample_rate:)
          dry = sample.to_f
          coefficient = modulated_coefficient(channel)
          wet = process_allpass_chain(dry + (@feedback_samples.fetch(channel) * @feedback), channel, coefficient)
          @feedback_samples[channel] = wet
          @lfo.next_value if channel == (@runtime_channels - 1)

          (dry * (1.0 - @mix)) + (wet * @mix)
        end

        def tail_duration
          return 0.0 if @mix.zero?

          pole = [MAX_ALLPASS_COEFFICIENT, @feedback.abs].max
          decay_samples = (Math.log(TAIL_AMPLITUDE) / Math.log(pole)).ceil
          (@stages * decay_samples) / REFERENCE_SAMPLE_RATE
        end

        private

        def prepare_runtime_state(sample_rate:, channels:)
          @lfo = DSP::LFO.new(rate: @rate, sample_rate: sample_rate)
          @stage_states = Array.new(channels) { Array.new(@stages, 0.0) }
          @feedback_samples = Array.new(channels, 0.0)
        end

        def reset_runtime_state
          @lfo = nil
          @stage_states = []
          @feedback_samples = []
        end

        def modulated_coefficient(channel)
          mod = (@lfo.value_at(channel_phase_offset(channel)) + 1.0) / 2.0
          (0.08 + (0.82 * @depth * mod)).clamp(0.02, 0.9)
        end

        def process_allpass_chain(input, channel, coefficient)
          output = input
          states = @stage_states.fetch(channel)
          states.each_index do |stage|
            delayed = states.fetch(stage)
            y = delayed - (coefficient * output)
            states[stage] = output + (coefficient * y)
            output = y
          end
          output
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

        def validate_stages!(value)
          unless value.is_a?(Integer) && value.between?(1, MAX_STAGES)
            raise InvalidParameterError, "stages must be an Integer in 1..#{MAX_STAGES}"
          end

          value
        end
      end
    end
  end
end
