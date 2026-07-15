# frozen_string_literal: true

module Wavify
  module DSP
    # Applies only the gain needed to keep each mixed frame within full scale.
    module Headroom
      DEFAULT_SMOOTHING_SECONDS = 0.005

      def self.apply!(samples, channels:, sample_rate:, smoothing_seconds: DEFAULT_SMOOTHING_SECONDS)
        smoothing = validate_smoothing!(smoothing_seconds)
        gains = frame_gains(samples, channels: channels, sample_rate: sample_rate, smoothing_seconds: smoothing)
        samples.each_index do |index|
          samples[index] = (samples.fetch(index) * gains.fetch(index / channels)).clamp(-1.0, 1.0)
        end
        samples
      end

      def self.frame_gains(samples, channels:, sample_rate:, smoothing_seconds:)
        gains = samples.each_slice(channels).map do |frame|
          peak = frame.reduce(0.0) { |maximum, sample| [maximum, sample.abs].max }
          peak > 1.0 ? 1.0 / peak : 1.0
        end
        return gains if gains.length < 2

        smoothing_frames = (sample_rate * smoothing_seconds).round
        return gains if smoothing_frames < 2

        smooth_gain_transitions(gains, smoothing_frames)
      end
      private_class_method :frame_gains

      def self.smooth_gain_transitions(targets, smoothing_frames)
        gains = targets.dup
        step = 1.0 / smoothing_frames

        1.upto(gains.length - 1) do |index|
          gains[index] = [gains.fetch(index), gains.fetch(index - 1) + step].min
        end
        (gains.length - 2).downto(0) do |index|
          gains[index] = [gains.fetch(index), gains.fetch(index + 1) + step].min
        end
        gains
      end
      private_class_method :smooth_gain_transitions

      def self.validate_smoothing!(value)
        unless value.is_a?(Numeric) && value.respond_to?(:finite?) && value.finite? && value >= 0.0
          raise InvalidParameterError, "headroom smoothing must be a non-negative finite Numeric"
        end

        value.to_f
      end
      private_class_method :validate_smoothing!
    end
  end
end
