# frozen_string_literal: true

module Wavify
  module Core
    # Immutable duration value object used across codecs and sequencer APIs.
    class Duration
      include Comparable

      attr_reader :total_seconds

      # Builds a duration from a frame count and sample rate.
      #
      # @param sample_frames [Integer]
      # @param sample_rate [Integer]
      # @return [Duration]
      def self.from_samples(sample_frames, sample_rate)
        unless sample_frames.is_a?(Integer) && sample_frames >= 0
          raise InvalidParameterError, "sample_frames must be a non-negative Integer: #{sample_frames.inspect}"
        end
        unless sample_rate.is_a?(Integer) && sample_rate.positive?
          raise InvalidParameterError, "sample_rate must be a positive Integer: #{sample_rate.inspect}"
        end

        new(sample_frames.to_f / sample_rate)
      end

      # @param total_seconds [Numeric] non-negative duration in seconds
      def initialize(total_seconds)
        unless total_seconds.is_a?(Numeric) && total_seconds >= 0
          raise InvalidParameterError, "total_seconds must be a non-negative Numeric: #{total_seconds.inspect}"
        end

        @total_seconds = total_seconds.to_f
      end

      # Compares two durations.
      #
      # @param other [Duration]
      # @return [-1, 0, 1, nil]
      def <=>(other)
        return nil unless other.is_a?(Duration)

        @total_seconds <=> other.total_seconds
      end

      def +(other)
        raise InvalidParameterError, "expected Duration: #{other.inspect}" unless other.is_a?(Duration)

        self.class.new(@total_seconds + other.total_seconds)
      end

      def -(other)
        raise InvalidParameterError, "expected Duration: #{other.inspect}" unless other.is_a?(Duration)

        value = @total_seconds - other.total_seconds
        raise InvalidParameterError, "resulting duration cannot be negative: #{value}" if value.negative?

        self.class.new(value)
      end

      # @return [Integer] hours component for {#to_s}
      def hours
        (total_milliseconds / 3_600_000).floor
      end

      # @return [Integer] minutes component for {#to_s}
      def minutes
        ((total_milliseconds % 3_600_000) / 60_000).floor
      end

      # @return [Integer] seconds component for {#to_s}
      def seconds
        ((total_milliseconds % 60_000) / 1000).floor
      end

      # @return [Integer] milliseconds component for {#to_s}
      def milliseconds
        (total_milliseconds % 1000).floor
      end

      # Returns a clock-style string (`HH:MM:SS.mmm`).
      #
      # @return [String]
      def to_s
        format("%<hours>02d:%<minutes>02d:%<seconds>02d.%<milliseconds>03d",
               hours: hours,
               minutes: minutes,
               seconds: seconds,
               milliseconds: milliseconds)
      end

      private

      def total_milliseconds
        (@total_seconds * 1000).round
      end
    end
  end
end
