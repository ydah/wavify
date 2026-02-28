# frozen_string_literal: true

module Wavify
  module DSP
    # ADSR envelope generator and buffer processor.
    class Envelope
      attr_reader :attack, :decay, :sustain, :release

      def initialize(attack:, decay:, sustain:, release:)
        @attack = validate_time!(attack, :attack)
        @decay = validate_time!(decay, :decay)
        @sustain = validate_sustain!(sustain)
        @release = validate_time!(release, :release)
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

        return attack_gain(time) if time < @attack
        return decay_gain(time) if time < (@attack + @decay)
        return @sustain if time < note_on_duration

        release_time = time - note_on_duration
        release_gain(release_time)
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

        time / @attack
      end

      def decay_gain(time)
        return @sustain if @decay.zero?

        elapsed = time - @attack
        1.0 - ((1.0 - @sustain) * (elapsed / @decay))
      end

      def release_gain(release_time)
        return 0.0 if @release.zero?

        @sustain * (1.0 - [release_time / @release, 1.0].min)
      end

      def validate_time!(value, name)
        raise InvalidParameterError, "#{name} must be a non-negative Numeric" unless value.is_a?(Numeric) && value >= 0

        value.to_f
      end

      def validate_sustain!(value)
        raise InvalidParameterError, "sustain must be Numeric in 0.0..1.0" unless value.is_a?(Numeric) && value.between?(0.0, 1.0)

        value.to_f
      end
    end
  end
end
