# frozen_string_literal: true

module Wavify
  module DSP
    # Oscillator and noise source generator.
    class Oscillator
      # Supported waveform symbols.
      WAVEFORMS = %i[sine square sawtooth triangle white_noise pink_noise].freeze

      def initialize(waveform:, frequency:, amplitude: 1.0, phase: 0.0, random: Random.new)
        @waveform = validate_waveform!(waveform)
        @frequency = validate_frequency!(frequency)
        @amplitude = validate_amplitude!(amplitude)
        @phase = phase.to_f
        @random = random
        reset_pink_noise!
      end

      # Generates a finite sample buffer in the requested format.
      #
      # @param duration_seconds [Numeric]
      # @param format [Wavify::Core::Format]
      # @return [Wavify::Core::SampleBuffer]
      def generate(duration_seconds, format:)
        validate_format!(format)
        unless duration_seconds.is_a?(Numeric) && duration_seconds >= 0
          raise InvalidParameterError, "duration_seconds must be a non-negative Numeric"
        end

        sample_frames = (duration_seconds.to_f * format.sample_rate).round
        samples = Array.new(sample_frames * format.channels)

        sample_frames.times do |frame_index|
          value = sample_at(frame_index, format.sample_rate)
          base_index = frame_index * format.channels
          format.channels.times { |channel| samples[base_index + channel] = value }
        end

        Core::SampleBuffer.new(samples, format)
      end

      # Returns an infinite enumerator of mono sample values.
      #
      # @param format [Wavify::Core::Format]
      # @return [Enumerator<Float>]
      def each_sample(format:)
        validate_format!(format)

        Enumerator.new do |yielder|
          index = 0
          loop do
            yielder << sample_at(index, format.sample_rate)
            index += 1
          end
        end
      end

      private

      def validate_waveform!(waveform)
        value = waveform.to_sym
        raise InvalidParameterError, "unsupported waveform: #{waveform.inspect}" unless WAVEFORMS.include?(value)

        value
      rescue NoMethodError
        raise InvalidParameterError, "waveform must be Symbol/String: #{waveform.inspect}"
      end

      def validate_frequency!(frequency)
        raise InvalidParameterError, "frequency must be a positive Numeric" unless frequency.is_a?(Numeric) && frequency.positive?

        frequency.to_f
      end

      def validate_amplitude!(amplitude)
        raise InvalidParameterError, "amplitude must be Numeric in 0.0..1.0" unless amplitude.is_a?(Numeric) && amplitude.between?(0.0, 1.0)

        amplitude.to_f
      end

      def validate_format!(format)
        raise InvalidParameterError, "format must be Core::Format" unless format.is_a?(Core::Format)
      end

      def sample_at(index, sample_rate)
        t = @phase + (index.to_f / sample_rate)
        raw = case @waveform
              when :sine then Math.sin(2.0 * Math::PI * @frequency * t)
              when :square then Math.sin(2.0 * Math::PI * @frequency * t) >= 0 ? 1.0 : -1.0
              when :sawtooth then (2.0 * ((@frequency * t) % 1.0)) - 1.0
              when :triangle then (2.0 * ((2.0 * ((@frequency * t) % 1.0)) - 1.0).abs) - 1.0
              when :white_noise then @random.rand(-1.0..1.0)
              when :pink_noise then next_pink_noise
              end
        (raw * @amplitude).clamp(-1.0, 1.0)
      end

      # Lightweight pink-noise approximation (Paul Kellet filter).
      def next_pink_noise
        white = @random.rand(-1.0..1.0)

        @pink_b0 = (0.99765 * @pink_b0) + (white * 0.0990460)
        @pink_b1 = (0.96300 * @pink_b1) + (white * 0.2965164)
        @pink_b2 = (0.57000 * @pink_b2) + (white * 1.0526913)
        @pink_b3 = (0.7616 * @pink_b3) - (white * 0.5511934)
        @pink_b4 = (0.8500 * @pink_b4) - (white * 0.7616)
        @pink_b5 = white * 0.115926

        @pink_b0 + @pink_b1 + @pink_b2 + @pink_b3 + @pink_b4 + @pink_b5 + (white * 0.5362)
      end

      def reset_pink_noise!
        @pink_b0 = 0.0
        @pink_b1 = 0.0
        @pink_b2 = 0.0
        @pink_b3 = 0.0
        @pink_b4 = 0.0
        @pink_b5 = 0.0
      end

    end
  end
end
