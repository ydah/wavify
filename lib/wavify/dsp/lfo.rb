# frozen_string_literal: true

module Wavify
  module DSP
    # Low frequency oscillator for modulation sources.
    class LFO
      WAVEFORMS = %i[sine triangle square sawtooth].freeze

      def initialize(rate:, sample_rate:, waveform: :sine, phase: 0.0)
        @rate = validate_positive!(rate, :rate)
        @sample_rate = validate_positive!(sample_rate, :sample_rate)
        @waveform = validate_waveform!(waveform)
        @initial_phase = phase.to_f % 1.0
        reset
      end

      def next_value
        value = value_at_phase(@phase)
        @phase = (@phase + (@rate / @sample_rate)) % 1.0
        value
      end

      def value_at(offset = 0.0)
        value_at_phase((@phase + offset.to_f) % 1.0)
      end

      def reset
        @phase = @initial_phase
        self
      end

      private

      def value_at_phase(phase)
        case @waveform
        when :sine
          Math.sin(2.0 * Math::PI * phase)
        when :triangle
          1.0 - (4.0 * (phase - 0.5).abs)
        when :square
          phase < 0.5 ? 1.0 : -1.0
        when :sawtooth
          (2.0 * phase) - 1.0
        end
      end

      def validate_positive!(value, name)
        unless value.is_a?(Numeric) && value.respond_to?(:finite?) && value.finite? && value.positive?
          raise InvalidParameterError, "#{name} must be a positive finite Numeric"
        end

        value.to_f
      end

      def validate_waveform!(waveform)
        value = waveform.to_sym
        return value if WAVEFORMS.include?(value)

        raise InvalidParameterError, "unsupported LFO waveform: #{waveform.inspect}"
      rescue NoMethodError
        raise InvalidParameterError, "waveform must be Symbol/String: #{waveform.inspect}"
      end
    end
  end
end
