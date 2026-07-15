# frozen_string_literal: true

module Wavify
  module DSP
    # Linear automation curve for time-varying parameters.
    class Automation
      Point = Struct.new(:time, :value, keyword_init: true)

      attr_reader :points

      def initialize(points)
        normalized = Array(points).map { |point| coerce_point(point) }.sort_by(&:time)
        raise InvalidParameterError, "automation points must not be empty" if normalized.empty?

        @points = normalized.freeze
      end

      def value_at(time)
        seconds = validate_time!(time)
        return @points.first.value if seconds <= @points.first.time
        return @points.last.value if seconds >= @points.last.time

        right_index = @points.bsearch_index { |point| point.time >= seconds }
        left = @points.fetch(right_index - 1)
        right = @points.fetch(right_index)
        span = right.time - left.time
        return right.value if span.zero?

        ratio = (seconds - left.time) / span
        left.value + ((right.value - left.value) * ratio)
      end

      def apply(buffer)
        raise InvalidParameterError, "buffer must be Core::SampleBuffer" unless buffer.is_a?(Core::SampleBuffer)
        raise InvalidParameterError, "automation apply requires a block" unless block_given?

        format = buffer.format
        point_index = 1
        samples = []
        buffer.samples.each_slice(format.channels).with_index do |frame, frame_index|
          time = frame_index.to_f / format.sample_rate
          point_index += 1 while point_index < @points.length && @points.fetch(point_index).time < time
          value = value_between_points(time, point_index)
          frame.each_with_index do |sample, channel|
            samples << yield(sample, value, time, channel)
          end
        end
        Core::SampleBuffer.new(samples, format)
      end

      def apply_gain(buffer, unit: :db)
        mode = unit.to_sym
        raise InvalidParameterError, "unit must be :db or :linear" unless %i[db linear].include?(mode)

        float_format = buffer.format.with(sample_format: :float, bit_depth: 32)
        processed = apply(buffer.convert(float_format)) do |sample, value, _time, _channel|
          factor = mode == :db ? (10.0**(value / 20.0)) : value
          sample * factor
        end
        processed.convert(buffer.format)
      rescue NoMethodError
        raise InvalidParameterError, "unit must be Symbol/String"
      end

      private

      def value_between_points(time, right_index)
        return @points.first.value if time <= @points.first.time
        return @points.last.value if right_index >= @points.length

        left = @points.fetch(right_index - 1)
        right = @points.fetch(right_index)
        span = right.time - left.time
        return right.value if span.zero?

        ratio = (time - left.time) / span
        left.value + ((right.value - left.value) * ratio)
      end

      def coerce_point(point)
        time, value = case point
                      when Point
                        [point.time, point.value]
                      when Hash
                        [point.fetch(:time), point.fetch(:value)]
                      else
                        point.to_a
                      end
        Point.new(time: validate_time!(time), value: validate_value!(value)).freeze
      rescue KeyError, NoMethodError
        raise InvalidParameterError, "automation point must provide time and value"
      end

      def validate_time!(time)
        unless time.is_a?(Numeric) && time.respond_to?(:finite?) && time.finite? && time >= 0.0
          raise InvalidParameterError, "automation time must be a non-negative finite Numeric"
        end

        time.to_f
      end

      def validate_value!(value)
        raise InvalidParameterError, "automation value must be a finite Numeric" unless value.is_a?(Numeric) && value.respond_to?(:finite?) && value.finite?

        value.to_f
      end
    end
  end
end
