# frozen_string_literal: true

module Wavify
  module DSP
    module Effects
      # Simple downward gate for suppressing low-level noise.
      class NoiseGate < EffectBase
        include EnvelopeControlledEffect

        def initialize(threshold: -40.0, floor: -80.0, attack: 0.001, hold: 0.02, release: 0.05)
          super()
          @threshold_db = validate_dbfs!(threshold, :threshold)
          @floor_db = validate_dbfs!(floor, :floor)
          @threshold = db_to_amplitude(@threshold_db)
          @floor_gain = db_to_amplitude(@floor_db)
          @envelope_follower = EnvelopeFollower.new(attack: attack, hold: hold, release: release)
          reset
        end

        private

        def gain_for_envelope(envelope)
          envelope < @threshold ? @floor_gain : 1.0
        end

        def validate_dbfs!(value, name)
          unless value.is_a?(Numeric) && value.respond_to?(:finite?) && value.finite? && value <= 0.0
            raise InvalidParameterError, "#{name} must be a finite Numeric <= 0 dBFS"
          end

          value.to_f
        end

        def db_to_amplitude(db)
          10.0**(db / 20.0)
        end
      end
    end
  end
end
