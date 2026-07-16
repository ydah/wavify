# frozen_string_literal: true

module Wavify
  module DSP
    module Effects
      # Downward expander that reduces low-level material below a threshold.
      class Expander < EffectBase
        include EnvelopeControlledEffect

        def initialize(threshold: -40.0, ratio: 2.0, floor: -80.0, attack: 0.001, hold: 0.02, release: 0.05,
                       gain_attack: 0.001, gain_release: 0.05)
          super()
          @threshold_db = validate_dbfs!(threshold, :threshold)
          @ratio = validate_ratio!(ratio)
          @floor_db = validate_dbfs!(floor, :floor)
          @floor_gain = db_to_amplitude(@floor_db)
          @gain_attack = validate_time!(gain_attack, :gain_attack)
          @gain_release = validate_time!(gain_release, :gain_release)
          @envelope_follower = EnvelopeFollower.new(attack: attack, hold: hold, release: release)
          reset
        end

        private

        def gain_for_envelope(envelope)
          target = target_gain_for_envelope(envelope)
          coefficient = target > @gain ? @gain_attack_coefficient : @gain_release_coefficient
          @gain = target + (coefficient * (@gain - target))
        end

        def target_gain_for_envelope(envelope)
          return 1.0 if envelope <= 0.0

          input_db = 20.0 * Math.log10(envelope)
          return 1.0 if input_db >= @threshold_db

          gain_reduction_db = (@threshold_db - input_db) * (@ratio - 1.0)
          [db_to_amplitude(-gain_reduction_db), @floor_gain].max
        end

        def prepare_runtime_state(sample_rate:, channels:)
          super
          @gain_attack_coefficient = time_coefficient(@gain_attack, sample_rate)
          @gain_release_coefficient = time_coefficient(@gain_release, sample_rate)
        end

        def reset_runtime_state
          super
          @gain = 1.0
          @gain_attack_coefficient = nil
          @gain_release_coefficient = nil
        end

        def validate_dbfs!(value, name)
          unless value.is_a?(Numeric) && value.respond_to?(:finite?) && value.finite? && value <= 0.0
            raise InvalidParameterError, "#{name} must be a finite Numeric <= 0 dBFS"
          end

          value.to_f
        end

        def validate_ratio!(value)
          unless value.is_a?(Numeric) && value.respond_to?(:finite?) && value.finite? && value >= 1.0
            raise InvalidParameterError, "ratio must be a finite Numeric >= 1.0"
          end

          value.to_f
        end

        def validate_time!(value, name)
          unless value.is_a?(Numeric) && value.respond_to?(:finite?) && value.finite? && value >= 0.0
            raise InvalidParameterError, "#{name} must be a non-negative finite Numeric"
          end

          value.to_f
        end

        def time_coefficient(seconds, sample_rate)
          return 0.0 if seconds.zero?

          Math.exp(-1.0 / (seconds * sample_rate))
        end

        def db_to_amplitude(db)
          10.0**(db / 20.0)
        end
      end
    end
  end
end
