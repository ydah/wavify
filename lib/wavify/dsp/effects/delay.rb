# frozen_string_literal: true

module Wavify
  module DSP
    module Effects
      # Simple feedback delay effect.
      class Delay < EffectBase
        NOTE_MULTIPLIERS = {
          whole: 4.0,
          half: 2.0,
          quarter: 1.0,
          eighth: 0.5,
          sixteenth: 0.25,
          thirty_second: 0.125
        }.freeze

        # Builds a tempo-synced delay.
        #
        # @param note [Symbol, String] note value such as `:quarter` or `:eighth`
        # @param tempo [Numeric] beats per minute
        # @param dotted [Boolean] multiply by 1.5
        # @param triplet [Boolean] multiply by 2/3
        # @return [Delay]
        def self.beat(note, tempo:, dotted: false, triplet: false, feedback: 0.5, mix: 0.3)
          multiplier = note_multiplier!(note)
          unless tempo.is_a?(Numeric) && tempo.respond_to?(:finite?) && tempo.finite? && tempo.positive?
            raise InvalidParameterError, "tempo must be a positive finite Numeric"
          end
          raise InvalidParameterError, "dotted and triplet cannot both be true" if dotted && triplet

          multiplier *= 1.5 if dotted
          multiplier *= (2.0 / 3.0) if triplet
          new(time: (60.0 / tempo.to_f) * multiplier, feedback: feedback, mix: mix)
        end

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

        # @return [Float] estimated feedback tail duration in seconds
        def tail_duration
          return 0.0 if @mix.zero?
          return @time if @feedback.zero?

          repeats = (Math.log(0.001) / Math.log(@feedback)).ceil
          @time * [[repeats, 1].max, 32].min
        end

        private

        def self.note_multiplier!(note)
          normalized = note.to_sym if note.respond_to?(:to_sym)
          return NOTE_MULTIPLIERS.fetch(normalized) if NOTE_MULTIPLIERS.key?(normalized)

          raise InvalidParameterError, "note must be one of: #{NOTE_MULTIPLIERS.keys.join(', ')}"
        end
        private_class_method :note_multiplier!

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
