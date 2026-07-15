# frozen_string_literal: true

module Wavify
  module DSP
    module Effects
      # Peak envelope detector with attack, hold, and release timing.
      class EnvelopeFollower
        def initialize(attack:, hold:, release:)
          @attack = validate_time!(attack, :attack)
          @hold = validate_time!(hold, :hold)
          @release = validate_time!(release, :release)
          reset
        end

        def prepare(sample_rate)
          @attack_coefficient = time_coefficient(@attack, sample_rate)
          @release_coefficient = time_coefficient(@release, sample_rate)
          @hold_frames = (@hold * sample_rate).round
          reset
        end

        def follow(level)
          if level > @envelope
            @envelope = level + (@attack_coefficient * (@envelope - level))
            @hold_remaining = @hold_frames
          elsif @hold_remaining.positive?
            @hold_remaining -= 1
          else
            @envelope = level + (@release_coefficient * (@envelope - level))
          end
          @envelope
        end

        def reset
          @envelope = 0.0
          @hold_remaining = 0
          self
        end

        private

        def time_coefficient(seconds, sample_rate)
          return 0.0 if seconds.zero?

          Math.exp(-1.0 / (seconds * sample_rate))
        end

        def validate_time!(value, name)
          unless value.is_a?(Numeric) && value.respond_to?(:finite?) && value.finite? && value >= 0.0
            raise InvalidParameterError, "#{name} must be a non-negative finite Numeric"
          end

          value.to_f
        end
      end
      private_constant :EnvelopeFollower

      # Shared frame-linked processing for gate and expansion effects.
      module EnvelopeControlledEffect
        def process(buffer)
          raise InvalidParameterError, "buffer must be Core::SampleBuffer" unless buffer.is_a?(Core::SampleBuffer)

          float_format = buffer.format.with(sample_format: :float, bit_depth: 32)
          float_buffer = buffer.convert(float_format)
          prepare_runtime_if_needed!(sample_rate: float_format.sample_rate, channels: float_format.channels)

          output = []
          float_buffer.samples.each_slice(@runtime_channels) do |frame|
            envelope = @envelope_follower.follow(frame.reduce(0.0) { |peak, sample| [peak, sample.abs].max })
            gain = gain_for_envelope(envelope)
            output.concat(frame.map { |sample| sample * gain })
          end
          Core::SampleBuffer.new(output, float_format).convert(buffer.format)
        end

        def process_sample(_sample, channel:, sample_rate:)
          raise NotImplementedError, "#{self.class} requires frame-aware #apply or #process"
        end

        private

        def prepare_runtime_state(sample_rate:, channels:)
          @envelope_follower.prepare(sample_rate)
        end

        def reset_runtime_state
          @envelope_follower.reset
        end
      end
      private_constant :EnvelopeControlledEffect
    end
  end
end
