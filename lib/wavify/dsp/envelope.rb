# frozen_string_literal: true

module Wavify
  module DSP
    # AHDSR envelope generator and buffer processor.
    class Envelope
      CURVES = %i[linear exp log].freeze # :nodoc:

      attr_reader :attack, :hold, :decay, :sustain, :release, :curve

      def initialize(attack:, decay:, sustain:, release:, hold: 0.0, curve: :linear)
        @attack = validate_time!(attack, :attack)
        @hold = validate_time!(hold, :hold)
        @decay = validate_time!(decay, :decay)
        @sustain = validate_sustain!(sustain)
        @release = validate_time!(release, :release)
        @curve = validate_curve!(curve)
      end

      # Computes envelope gain at a given playback time.
      #
      # @param time [Numeric]
      # @param note_on_duration [Numeric]
      # @return [Float]
      def gain_at(time, note_on_duration:)
        raise InvalidParameterError, "time must be a non-negative Numeric" unless time.is_a?(Numeric) && time >= 0
        unless note_on_duration.is_a?(Numeric) && note_on_duration >= 0
          raise InvalidParameterError, "note_on_duration must be a non-negative Numeric"
        end

        return sustain_stage_gain(time) if time < note_on_duration

        release_time = time - note_on_duration
        release_gain(release_time, start_gain: sustain_stage_gain(note_on_duration))
      end

      # Applies the envelope to a sample buffer.
      #
      # @param buffer [Wavify::Core::SampleBuffer]
      # @param note_on_duration [Numeric]
      # @return [Wavify::Core::SampleBuffer]
      def apply(buffer, note_on_duration:)
        raise InvalidParameterError, "buffer must be Core::SampleBuffer" unless buffer.is_a?(Core::SampleBuffer)
        unless note_on_duration.is_a?(Numeric) && note_on_duration >= 0
          raise InvalidParameterError, "note_on_duration must be a non-negative Numeric"
        end

        float_format = buffer.format.with(sample_format: :float, bit_depth: 32)
        float_buffer = buffer.convert(float_format)
        channels = float_format.channels
        sample_rate = float_format.sample_rate

        processed = float_buffer.samples.dup
        processed.each_slice(channels).with_index do |frame, frame_index|
          gain = gain_at(frame_index.to_f / sample_rate, note_on_duration: note_on_duration)
          base = frame_index * channels
          frame.each_index do |channel_index|
            processed[base + channel_index] = frame[channel_index] * gain
          end
        end

        Core::SampleBuffer.new(processed, float_format).convert(buffer.format)
      end

      private

      def attack_gain(time)
        return 1.0 if @attack.zero?

        curve_factor(time / @attack)
      end

      def decay_gain(time)
        return @sustain if @decay.zero?

        elapsed = time - @attack - @hold
        progress = curve_factor(elapsed / @decay)
        1.0 - ((1.0 - @sustain) * progress)
      end

      def release_gain(release_time, start_gain:)
        return 0.0 if @release.zero?

        start_gain * (1.0 - curve_factor(release_time / @release))
      end

      def sustain_stage_gain(time)
        return attack_gain(time) if time < @attack
        return 1.0 if time < (@attack + @hold)
        return decay_gain(time) if time < (@attack + @hold + @decay)

        @sustain
      end

      def curve_factor(value)
        progress = value.clamp(0.0, 1.0)
        case @curve
        when :linear
          progress
        when :exp
          progress * progress
        when :log
          Math.log10(1.0 + (9.0 * progress))
        end
      end

      def validate_time!(value, name)
        unless value.is_a?(Numeric) && value.respond_to?(:finite?) && value.finite? && value >= 0
          raise InvalidParameterError, "#{name} must be a non-negative finite Numeric"
        end

        value.to_f
      end

      def validate_sustain!(value)
        raise InvalidParameterError, "sustain must be Numeric in 0.0..1.0" unless value.is_a?(Numeric) && value.between?(0.0, 1.0)

        value.to_f
      end

      def validate_curve!(value)
        normalized = value.to_sym if value.respond_to?(:to_sym)
        return normalized if CURVES.include?(normalized)

        raise InvalidParameterError, "curve must be one of: #{CURVES.join(', ')}"
      end
    end
  end
end
