# frozen_string_literal: true

module Wavify
  module DSP
    # Applies overlap-aware gain while smoothing source-count transitions.
    module Headroom
      SMOOTHING_SECONDS = 0.005

      def self.apply!(samples, active_sources:, channels:, sample_rate:, fallback_sources: 1)
        divisors = frame_divisors(
          active_sources,
          channels: channels,
          sample_rate: sample_rate,
          fallback_sources: fallback_sources,
          frame_count: samples.length / channels
        )
        samples.each_index do |index|
          samples[index] = (samples.fetch(index) / divisors.fetch(index / channels)).clamp(-1.0, 1.0)
        end
        samples
      end

      def self.frame_divisors(active_sources, channels:, sample_rate:, fallback_sources:, frame_count:)
        counts = if active_sources
                   active_sources.each_slice(channels).map { |frame| [frame.max || 0, 1].max.to_f }
                 else
                   Array.new(frame_count, [fallback_sources, 1].max.to_f)
                 end
        return counts if counts.length < 2

        smoothing_frames = (sample_rate * SMOOTHING_SECONDS).round
        return counts if smoothing_frames < 2

        smooth_source_transitions(counts, smoothing_frames)
      end
      private_class_method :frame_divisors

      def self.smooth_source_transitions(counts, smoothing_frames)
        divisors = counts.dup
        step = 1.0 / smoothing_frames

        1.upto(divisors.length - 1) do |index|
          divisors[index] = [divisors.fetch(index), divisors.fetch(index - 1) - step].max
        end
        (divisors.length - 2).downto(0) do |index|
          divisors[index] = [divisors.fetch(index), divisors.fetch(index + 1) - step].max
        end
        divisors
      end
      private_class_method :smooth_source_transitions
    end
  end
end
