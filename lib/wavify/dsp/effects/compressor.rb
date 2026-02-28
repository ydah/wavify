# frozen_string_literal: true

module Wavify
  module DSP
    module Effects
      # Peak compressor with threshold, ratio, attack, and release controls.
      class Compressor < EffectBase
        def initialize(threshold: -10, ratio: 4, attack: 0.01, release: 0.1)
          super()
          @threshold_db = validate_numeric!(threshold, :threshold).to_f
          @ratio = validate_ratio!(ratio)
          @attack = validate_time!(attack, :attack)
          @release = validate_time!(release, :release)
          reset
        end

        # Processes a single sample for one channel.
        #
        # @param sample [Numeric]
        # @param channel [Integer]
        # @param sample_rate [Integer]
        # @return [Float]
        def process_sample(sample, channel:, sample_rate:)
          x = sample.to_f
          level = x.abs

          attack_coeff = time_coefficient(@attack, sample_rate)
          release_coeff = time_coefficient(@release, sample_rate)
          envelope = @envelopes.fetch(channel)
          coeff = level > envelope ? attack_coeff : release_coeff
          envelope += (1.0 - coeff) * (level - envelope)
          @envelopes[channel] = envelope

          gain = gain_for_envelope(envelope)
          x * gain
        end

        private

        def prepare_runtime_state(sample_rate:, channels:)
          @envelopes = Array.new(channels, 0.0)
          @threshold_linear = 10.0**(@threshold_db / 20.0)
        end

        def reset_runtime_state
          @envelopes = []
          @threshold_linear = nil
        end

        def gain_for_envelope(envelope)
          return 1.0 if envelope <= 0.0 || envelope <= @threshold_linear

          input_db = 20.0 * Math.log10(envelope)
          output_db = @threshold_db + ((input_db - @threshold_db) / @ratio)
          gain_db = output_db - input_db
          10.0**(gain_db / 20.0)
        end

        def time_coefficient(seconds, sample_rate)
          return 0.0 if seconds <= 0.0

          Math.exp(-1.0 / (seconds * sample_rate))
        end

        def validate_numeric!(value, name)
          raise InvalidParameterError, "#{name} must be Numeric" unless value.is_a?(Numeric)

          value
        end

        def validate_ratio!(value)
          raise InvalidParameterError, "ratio must be >= 1.0" unless value.is_a?(Numeric) && value >= 1.0

          value.to_f
        end

        def validate_time!(value, name)
          raise InvalidParameterError, "#{name} must be a non-negative Numeric" unless value.is_a?(Numeric) && value >= 0.0

          value.to_f
        end
      end
    end
  end
end
