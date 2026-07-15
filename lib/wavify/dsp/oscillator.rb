# frozen_string_literal: true

module Wavify
  module DSP
    # Oscillator and noise source generator.
    class Oscillator
      # Supported waveform symbols.
      WAVEFORMS = %i[sine square sawtooth triangle pulse white_noise pink_noise].freeze
      # Sample count in each band-limited triangle wavetable.
      TRIANGLE_TABLE_SIZE = 2_048
      # Highest odd harmonic considered when building triangle tables.
      TRIANGLE_MAX_HARMONIC = 255
      # Maximum number of sample-rate/frequency-specific tables retained.
      TRIANGLE_TABLE_CACHE_LIMIT = 8
      # Maximum duration accepted by one eager generation call.
      MAX_DURATION_SECONDS = 3_600.0
      # Maximum number of frames allocated by one eager generation call.
      MAX_GENERATE_FRAMES = 50_000_000
      # Absolute input guard before output-format Nyquist validation.
      MAX_FREQUENCY = 1_000_000.0
      # Maximum number of detuned oscillator voices.
      MAX_UNISON = 64

      # @param phase [Numeric] initial phase in cycles (`0.0..1.0` wraps)
      def initialize(waveform:, frequency:, amplitude: 1.0, phase: 0.0, pulse_width: 0.5, detune: 0.0, unison: 1,
                     random: Random.new)
        @waveform = validate_waveform!(waveform)
        @frequency = validate_frequency!(frequency)
        @amplitude = validate_amplitude!(amplitude)
        @initial_phase = validate_phase!(phase)
        @voice_phases = nil
        @voice_frequencies = nil
        @sample_rate = nil
        @pulse_width = validate_pulse_width!(pulse_width)
        @detune = validate_detune!(detune)
        @unison = validate_unison!(unison)
        @random = random
        @triangle_tables = {}
        reset_pink_noise!
      end

      def reset_phase(phase = @initial_phase)
        @initial_phase = validate_phase!(phase)
        @voice_phases = nil
        @voice_frequencies = nil
        @sample_rate = nil
        reset_pink_noise!
        self
      end

      # Generates the next finite sample buffer in the requested format.
      # Calls are stateful and continue oscillator phase. Call {#reset_phase}
      # before changing sample rate or when repeatable output is required.
      #
      # @param duration_seconds [Numeric]
      # @param format [Wavify::Core::Format]
      # @return [Wavify::Core::SampleBuffer]
      def generate(duration_seconds, format:)
        validate_format!(format)
        prepare_sample_rate!(format.sample_rate)
        unless duration_seconds.is_a?(Numeric) && duration_seconds.respond_to?(:finite?) && duration_seconds.finite? &&
               duration_seconds.between?(0.0, MAX_DURATION_SECONDS)
          raise InvalidParameterError, "duration_seconds must be a finite Numeric in 0.0..#{MAX_DURATION_SECONDS}"
        end

        sample_frames = (duration_seconds.to_f * format.sample_rate).round
        if sample_frames > MAX_GENERATE_FRAMES
          raise InvalidParameterError, "generation is limited to #{MAX_GENERATE_FRAMES} sample frames"
        end
        samples = Array.new(sample_frames * format.channels)

        sample_frames.times do |frame_index|
          base_index = frame_index * format.channels
          if noise_waveform?
            format.channels.times { |channel| samples[base_index + channel] = scaled_noise_sample }
          else
            value = next_periodic_sample(format.sample_rate)
            format.channels.times { |channel| samples[base_index + channel] = value }
          end
        end

        Core::SampleBuffer.new(samples, format)
      end

      # Returns a stateful infinite enumerator of mono sample values.
      #
      # @param format [Wavify::Core::Format]
      # @return [Enumerator<Float>]
      def each_sample(format:)
        validate_format!(format)
        prepare_sample_rate!(format.sample_rate)

        Enumerator.new do |yielder|
          loop do
            value = noise_waveform? ? scaled_noise_sample : next_periodic_sample(format.sample_rate)
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
        unless frequency.is_a?(Numeric) && frequency.respond_to?(:finite?) && frequency.finite? &&
               frequency.positive? && frequency <= MAX_FREQUENCY
          raise InvalidParameterError, "frequency must be a positive finite Numeric <= #{MAX_FREQUENCY}"
        end

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
        unless unison.is_a?(Integer) && unison.between?(1, MAX_UNISON)
          raise InvalidParameterError, "unison must be an Integer in 1..#{MAX_UNISON}"
        end

        unison
      end

      def validate_format!(format)
        raise InvalidParameterError, "format must be Core::Format" unless format.is_a?(Core::Format)
      end

      def prepare_sample_rate!(sample_rate)
        if @sample_rate && @sample_rate != sample_rate
          raise InvalidParameterError, "sample_rate cannot change while phase is active; call reset_phase first"
        end

        if !noise_waveform? && oscillator_voice_frequencies.any? { |frequency| frequency > (sample_rate / 2.0) }
          raise InvalidParameterError, "oscillator frequency must not exceed Nyquist for the output format"
        end

        @sample_rate = sample_rate
        @voice_frequencies ||= oscillator_voice_frequencies.freeze
        @voice_phases ||= Array.new(@voice_frequencies.length, @initial_phase)
      end

      def next_periodic_sample(sample_rate)
        raw = @voice_frequencies.each_with_index.sum do |frequency, voice|
          oscillator_sample(@voice_phases.fetch(voice), sample_rate, frequency)
        end / @voice_frequencies.length
        advance_voice_phases!(sample_rate)
        (raw * @amplitude).clamp(-1.0, 1.0)
      end

      def oscillator_sample(phase, sample_rate, frequency)
        phase_step = frequency / sample_rate.to_f
        phase_step = 0.5 if phase_step > 0.5

        case @waveform
        when :sine then Math.sin(2.0 * Math::PI * phase)
        when :square then polyblep_square(phase, phase_step, 0.5)
        when :pulse then polyblep_square(phase, phase_step, @pulse_width)
        when :sawtooth then polyblep_saw(phase, phase_step)
        when :triangle then bandlimited_triangle(phase, frequency, sample_rate)
        end
      end

      def advance_voice_phases!(sample_rate)
        @voice_phases.map!.with_index do |phase, voice|
          (phase + (@voice_frequencies.fetch(voice) / sample_rate.to_f)) % 1.0
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

      def bandlimited_triangle(phase, frequency, sample_rate)
        table = triangle_wavetable(frequency, sample_rate)
        position = phase * TRIANGLE_TABLE_SIZE
        left_index = position.floor % TRIANGLE_TABLE_SIZE
        right_index = (left_index + 1) % TRIANGLE_TABLE_SIZE
        fraction = position - position.floor
        table.fetch(left_index) + ((table.fetch(right_index) - table.fetch(left_index)) * fraction)
      end

      def triangle_wavetable(frequency, sample_rate)
        key = [frequency, sample_rate]
        return @triangle_tables.fetch(key) if @triangle_tables.key?(key)

        @triangle_tables.shift if @triangle_tables.length >= TRIANGLE_TABLE_CACHE_LIMIT
        highest = [((sample_rate / 2.0) / frequency).floor, TRIANGLE_MAX_HARMONIC].min
        harmonics = (1..highest).step(2).to_a
        scale = 8.0 / (Math::PI * Math::PI)
        @triangle_tables[key] = Array.new(TRIANGLE_TABLE_SIZE) do |index|
          phase = index.to_f / TRIANGLE_TABLE_SIZE
          scale * harmonics.sum { |harmonic| Math.cos(2.0 * Math::PI * harmonic * phase) / (harmonic * harmonic) }
        end.freeze
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
