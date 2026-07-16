# frozen_string_literal: true

module Wavify
  module DSP
    module Effects
      # Simple downward gate for suppressing low-level noise.
      class NoiseGate < EffectBase
        include EnvelopeControlledEffect

        def initialize(threshold: -40.0, floor: -80.0, attack: 0.001, hold: 0.02, release: 0.05,
                       gain_attack: attack, gain_release: release)
          super()
          @threshold_db = validate_dbfs!(threshold, :threshold)
          @floor_db = validate_dbfs!(floor, :floor)
          @threshold = db_to_amplitude(@threshold_db)
          @floor_gain = db_to_amplitude(@floor_db)
          @gain_attack = validate_time!(gain_attack, :gain_attack)
          @gain_release = validate_time!(gain_release, :gain_release)
          @envelope_follower = EnvelopeFollower.new(attack: attack, hold: hold, release: release)
          reset
        end

        private

        def gain_for_envelope(envelope)
          target = envelope < @threshold ? @floor_gain : 1.0
          coefficient = target > @gain ? @gain_attack_coefficient : @gain_release_coefficient
          @gain = target + (coefficient * (@gain - target))
        end

        def prepare_runtime_state(sample_rate:, channels:)
          super
          @gain_attack_coefficient = time_coefficient(@gain_attack, sample_rate)
          @gain_release_coefficient = time_coefficient(@gain_release, sample_rate)
        end

        def reset_runtime_state
          super
          @gain = @floor_gain
          @gain_attack_coefficient = nil
          @gain_release_coefficient = nil
        end

        def validate_dbfs!(value, name)
          unless value.is_a?(Numeric) && value.respond_to?(:finite?) && value.finite? && value <= 0.0
            raise InvalidParameterError, "#{name} must be a finite Numeric <= 0 dBFS"
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
