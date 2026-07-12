# frozen_string_literal: true

module Wavify
  module DSP
    # Oscillator and noise source generator.
    class Oscillator
      # Supported waveform symbols.
      WAVEFORMS = %i[sine square sawtooth triangle pulse white_noise pink_noise].freeze

      # @param phase [Numeric] initial phase in cycles (`0.0..1.0` wraps)
      def initialize(waveform:, frequency:, amplitude: 1.0, phase: 0.0, pulse_width: 0.5, detune: 0.0, unison: 1,
                     random: Random.new)
        @waveform = validate_waveform!(waveform)
        @frequency = validate_frequency!(frequency)
        @amplitude = validate_amplitude!(amplitude)
        @initial_phase = validate_phase!(phase)
        @phase = @initial_phase
        @sample_position = 0
        @pulse_width = validate_pulse_width!(pulse_width)
        @detune = validate_detune!(detune)
        @unison = validate_unison!(unison)
        @random = random
        reset_pink_noise!
      end

      def reset_phase(phase = @initial_phase)
        @phase = validate_phase!(phase)
        @sample_position = 0
        reset_pink_noise!
        self
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
          base_index = frame_index * format.channels
          if noise_waveform?
            format.channels.times { |channel| samples[base_index + channel] = scaled_noise_sample }
          else
            value = sample_at(@sample_position, format.sample_rate)
            format.channels.times { |channel| samples[base_index + channel] = value }
          end
          @sample_position += 1
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
          loop do
            value = noise_waveform? ? scaled_noise_sample : sample_at(@sample_position, format.sample_rate)
            @sample_position += 1
            yielder << value
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

      def validate_phase!(phase)
        unless phase.is_a?(Numeric) && phase.respond_to?(:finite?) && phase.finite?
          raise InvalidParameterError, "phase must be a finite Numeric"
        end

        phase.to_f % 1.0
      end

      def validate_pulse_width!(pulse_width)
        unless pulse_width.is_a?(Numeric) && pulse_width.respond_to?(:finite?) && pulse_width.finite? && pulse_width.between?(0.01, 0.99)
          raise InvalidParameterError, "pulse_width must be a finite Numeric in 0.01..0.99"
        end

        pulse_width.to_f
      end

      def validate_detune!(detune)
        raise InvalidParameterError, "detune must be a finite Numeric" unless detune.is_a?(Numeric) && detune.respond_to?(:finite?) && detune.finite?

        detune.to_f
      end

      def validate_unison!(unison)
        voices = Integer(unison)
        raise InvalidParameterError, "unison must be positive" unless voices.positive?

        voices
      rescue ArgumentError, TypeError
        raise InvalidParameterError, "unison must be an Integer"
      end

      def validate_format!(format)
        raise InvalidParameterError, "format must be Core::Format" unless format.is_a?(Core::Format)
      end

      def sample_at(index, sample_rate)
        frequencies = oscillator_voice_frequencies
        raw = frequencies.sum do |frequency|
          oscillator_sample(index, sample_rate, frequency)
        end / frequencies.length
        (raw * @amplitude).clamp(-1.0, 1.0)
      end

      def oscillator_sample(index, sample_rate, frequency)
        phase = (@phase + (frequency * index.to_f / sample_rate)) % 1.0
        phase_step = frequency / sample_rate.to_f
        phase_step = 0.5 if phase_step > 0.5

        case @waveform
        when :sine then Math.sin(2.0 * Math::PI * phase)
        when :square then polyblep_square(phase, phase_step, 0.5)
        when :pulse then polyblep_square(phase, phase_step, @pulse_width)
        when :sawtooth then polyblep_saw(phase, phase_step)
        when :triangle then naive_triangle(phase)
        end
      end

      def noise_waveform?
        @waveform == :white_noise || @waveform == :pink_noise
      end

      def noise_sample
        raw = case @waveform
              when :white_noise then @random.rand(-1.0..1.0)
              when :pink_noise then next_pink_noise
              end
        raw || 0.0
      end

      def scaled_noise_sample
        (noise_sample * @amplitude).clamp(-1.0, 1.0)
      end

      def oscillator_voice_frequencies
        return [@frequency] if @unison == 1 || @detune.zero?

        center = (@unison - 1) / 2.0
        Array.new(@unison) do |voice|
          cents = (voice - center) * @detune
          @frequency * (2.0**(cents / 1200.0))
        end
      end

      def polyblep_saw(phase, phase_step)
        ((2.0 * phase) - 1.0) - polyblep(phase, phase_step)
      end

      def polyblep_square(phase, phase_step, pulse_width)
        value = phase < pulse_width ? 1.0 : -1.0
        value += polyblep(phase, phase_step)
        value -= polyblep((phase - pulse_width) % 1.0, phase_step)
        value
      end

      def naive_triangle(phase)
        (2.0 * ((2.0 * phase) - 1.0).abs) - 1.0
      end

      def polyblep(phase, phase_step)
        return 0.0 if phase_step <= 0.0

        if phase < phase_step
          t = phase / phase_step
          (t + t) - (t * t) - 1.0
        elsif phase > 1.0 - phase_step
          t = (phase - 1.0) / phase_step
          (t * t) + (t + t) + 1.0
        else
          0.0
        end
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
