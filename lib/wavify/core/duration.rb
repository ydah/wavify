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

      # Parses `SS.sss`, `MM:SS.sss`, or `HH:MM:SS.sss` text.
      #
      # @param value [String]
      # @return [Duration]
      def self.parse(value)
        raise InvalidParameterError, "duration must be a String" unless value.is_a?(String)

        parts = value.strip.split(":")
        component_count = parts.length
        raise InvalidParameterError, "invalid duration: #{value.inspect}" unless component_count.between?(1, 3)

        seconds = parse_seconds(parts.pop)
        minutes = parts.empty? ? 0.0 : parse_component(parts.pop, :minutes)
        hours = parts.empty? ? 0.0 : parse_component(parts.pop, :hours)
        raise InvalidParameterError, "invalid duration: #{value.inspect}" unless parts.empty?
        raise InvalidParameterError, "minutes must be less than 60" if component_count == 3 && minutes >= 60.0
        raise InvalidParameterError, "seconds must be less than 60" if component_count >= 2 && seconds >= 60.0

        new((hours * 3600.0) + (minutes * 60.0) + seconds)
      rescue ArgumentError
        raise InvalidParameterError, "invalid duration: #{value.inspect}"
      end

      # @param total_seconds [Numeric] non-negative duration in seconds
      def initialize(total_seconds)
        unless total_seconds.is_a?(Numeric) && total_seconds.respond_to?(:finite?) && total_seconds.finite? && total_seconds >= 0
          raise InvalidParameterError, "total_seconds must be a non-negative finite Numeric: #{total_seconds.inspect}"
        end

        @total_seconds = total_seconds.to_f
        freeze
      end

      # Compares two durations.
      #
      # @param other [Duration]
      # @return [-1, 0, 1, nil]
      def <=>(other)
        return nil unless other.is_a?(Duration)

        @total_seconds <=> other.total_seconds
      end

      def eql?(other)
        other.is_a?(Duration) && @total_seconds.eql?(other.total_seconds)
      end

      def hash
        @total_seconds.hash
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

      def self.parse_seconds(value)
        seconds = Float(value)
        unless seconds.finite? && !seconds.negative?
          raise InvalidParameterError, "seconds must be a non-negative finite number"
        end

        seconds
      end
      private_class_method :parse_seconds

      def self.parse_component(value, name)
        component = Float(value)
        unless component.finite? && !component.negative?
          raise InvalidParameterError, "#{name} must be a non-negative finite number"
        end

        component
      end
      private_class_method :parse_component

      def total_milliseconds
        (@total_seconds * 1000).round
      end
    end
  end
end
