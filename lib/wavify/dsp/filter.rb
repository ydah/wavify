# frozen_string_literal: true

module Wavify
  # Digital signal processing primitives.
  module DSP
    # Stateful biquad filter with common factory constructors.
    class Filter
      DEFAULT_TAIL_SECONDS = 0.05
      MAX_TAIL_SECONDS = 10.0
      TAIL_AMPLITUDE = 1.0e-6

      attr_reader :type, :cutoff, :q, :gain_db

      # Builds a low-pass filter.
      #
      # @return [Filter]
      def self.lowpass(cutoff:, q: 0.707)
        new(:lowpass, cutoff: cutoff, q: q)
      end

      # Builds a high-pass filter.
      #
      # @return [Filter]
      def self.highpass(cutoff:, q: 0.707)
        new(:highpass, cutoff: cutoff, q: q)
      end

      def self.bandpass(center: nil, bandwidth: nil, cutoff: nil, q: nil)
        return new(:bandpass, cutoff: cutoff, q: q || 0.707) if cutoff

        unless center.is_a?(Numeric) && center.respond_to?(:finite?) && center.finite? && center.positive?
          raise InvalidParameterError, "center must be a positive finite Numeric"
        end
        unless bandwidth.is_a?(Numeric) && bandwidth.respond_to?(:finite?) && bandwidth.finite? && bandwidth.positive?
          raise InvalidParameterError, "bandwidth must be a positive finite Numeric"
        end

        new(:bandpass, cutoff: center, q: center.to_f / bandwidth)
      end

      # Builds a notch filter.
      #
      # @return [Filter]
      def self.notch(cutoff:, q: 0.707)
        new(:notch, cutoff: cutoff, q: q)
      end

      # Builds a peaking EQ filter.
      #
      # @return [Filter]
      def self.peaking(cutoff:, q: 1.0, gain_db: 0.0)
        new(:peaking, cutoff: cutoff, q: q, gain_db: gain_db)
      end

      # Builds a low-shelf EQ filter.
      #
      # @return [Filter]
      def self.lowshelf(cutoff:, gain_db:)
        new(:lowshelf, cutoff: cutoff, gain_db: gain_db)
      end

      # Builds a high-shelf EQ filter.
      #
      # @return [Filter]
      def self.highshelf(cutoff:, gain_db:)
        new(:highshelf, cutoff: cutoff, gain_db: gain_db)
      end

      def initialize(type, cutoff:, q: 0.707, gain_db: 0.0)
        @type = validate_type!(type)
        @cutoff = validate_cutoff!(cutoff)
        @q = validate_q!(q)
        @gain_db = validate_gain!(gain_db)

        @coefficients = nil
        @coeff_sample_rate = nil
        @channel_states = []
      end

      def apply(buffer)
        raise InvalidParameterError, "buffer must be Core::SampleBuffer" unless buffer.is_a?(Core::SampleBuffer)

        float_format = buffer.format.with(sample_format: :float, bit_depth: 32)
        float_buffer = buffer.convert(float_format)
        processed = process_interleaved(
          float_buffer.samples,
          sample_rate: float_format.sample_rate,
          channels: float_format.channels
        )

        Core::SampleBuffer.new(processed, float_format).convert(buffer.format)
      end

      def process_sample(sample, sample_rate:, channel: 0)
        raise InvalidParameterError, "sample must be Numeric" unless sample.is_a?(Numeric)
        raise InvalidParameterError, "channel must be a non-negative Integer" unless channel.is_a?(Integer) && channel >= 0
        raise InvalidParameterError, "sample_rate must be a positive Integer" unless sample_rate.is_a?(Integer) && sample_rate.positive?

        update_coefficients!(sample_rate)
        ensure_channel_states!(channel + 1)
        state = @channel_states[channel]
        x = sample.to_f
        y = compute_biquad(state, x)
        update_state!(state, x, y)
        y
      end

      # Emits the decaying IIR state after the input ends.
      #
      # @param format [Core::Format, nil] optional target format
      # @return [Core::SampleBuffer, nil]
      def flush(format: nil)
        return nil unless @coeff_sample_rate && filter_state_active?
        if format && !format.is_a?(Core::Format)
          raise InvalidParameterError, "format must be Core::Format"
        end

        channels = @channel_states.length
        runtime_format = Core::Format.new(
          channels: channels,
          sample_rate: @coeff_sample_rate,
          bit_depth: 32,
          sample_format: :float
        )
        silence = Array.new(tail_frame_count(@coeff_sample_rate) * channels, 0.0)
        processed = process_interleaved(silence, sample_rate: @coeff_sample_rate, channels: channels)
        reset
        Core::SampleBuffer.new(processed, runtime_format).convert(format || runtime_format)
      end

      # Estimated time for the biquad poles to decay below -120 dB.
      def tail_duration
        return DEFAULT_TAIL_SECONDS unless @coeff_sample_rate && @coefficients

        tail_frame_count(@coeff_sample_rate).to_f / @coeff_sample_rate
      end

      # Clears internal filter state for all channels.
      #
      # @return [void]
      def reset
        @channel_states = []
      end

      private

      def filter_state_active?
        @channel_states.any? { |state| state.values.any? { |value| !value.zero? } }
      end

      def tail_frame_count(sample_rate)
        radius = maximum_pole_radius
        frames = if radius <= 0.0
                   2
                 elsif radius >= 1.0
                   (MAX_TAIL_SECONDS * sample_rate).ceil
                 else
                   (Math.log(TAIL_AMPLITUDE) / Math.log(radius)).ceil
                 end
        frames.clamp(2, (MAX_TAIL_SECONDS * sample_rate).ceil)
      end

      def maximum_pole_radius
        _b0, _b1, _b2, a1, a2 = @coefficients
        discriminant = (a1 * a1) - (4.0 * a2)
        return Math.sqrt(a2.abs) if discriminant.negative?

        root = Math.sqrt(discriminant)
        [(-a1 + root) / 2.0, (-a1 - root) / 2.0].map(&:abs).max
      end

      def process_interleaved(samples, sample_rate:, channels:)
        update_coefficients!(sample_rate)
        ensure_channel_states!(channels)

        output = Array.new(samples.length)
        samples.each_with_index do |sample, sample_index|
          channel = sample_index % channels
          state = @channel_states[channel]
          x = sample.to_f
          y = compute_biquad(state, x)
          update_state!(state, x, y)
          output[sample_index] = y
        end
        output
      end

      def update_coefficients!(sample_rate)
        return if @coeff_sample_rate == sample_rate && @coefficients

        validate_cutoff_below_nyquist!(sample_rate)
        @coefficients = coefficients_for(sample_rate)
        @coeff_sample_rate = sample_rate
        reset
      end

      def ensure_channel_states!(channels)
        return if @channel_states.length == channels

        @channel_states = Array.new(channels) { { x1: 0.0, x2: 0.0, y1: 0.0, y2: 0.0 } }
      end

      def compute_biquad(state, x)
        b0, b1, b2, a1, a2 = @coefficients
        (b0 * x) + (b1 * state[:x1]) + (b2 * state[:x2]) - (a1 * state[:y1]) - (a2 * state[:y2])
      end

      def update_state!(state, x, y)
        state[:x2] = state[:x1]
        state[:x1] = x
        state[:y2] = state[:y1]
        state[:y1] = y
      end

      def coefficients_for(sample_rate)
        omega = 2.0 * Math::PI * @cutoff / sample_rate
        cos_w = Math.cos(omega)
        sin_w = Math.sin(omega)
        alpha = sin_w / (2.0 * @q)
        a = 10.0**(@gain_db / 40.0)

        b0, b1, b2, a0, a1, a2 = case @type
                                 when :lowpass
                                   [
                                     (1.0 - cos_w) / 2.0,
                                     1.0 - cos_w,
                                     (1.0 - cos_w) / 2.0,
                                     1.0 + alpha,
                                     -2.0 * cos_w,
                                     1.0 - alpha
                                   ]
                                 when :highpass
                                   [
                                     (1.0 + cos_w) / 2.0,
                                     -(1.0 + cos_w),
                                     (1.0 + cos_w) / 2.0,
                                     1.0 + alpha,
                                     -2.0 * cos_w,
                                     1.0 - alpha
                                   ]
                                 when :bandpass
                                   [
                                     alpha,
                                     0.0,
                                     -alpha,
                                     1.0 + alpha,
                                     -2.0 * cos_w,
                                     1.0 - alpha
                                   ]
                                 when :notch
                                   [
                                     1.0,
                                     -2.0 * cos_w,
                                     1.0,
                                     1.0 + alpha,
                                     -2.0 * cos_w,
                                     1.0 - alpha
                                   ]
                                 when :peaking
                                   [
                                     1.0 + (alpha * a),
                                     -2.0 * cos_w,
                                     1.0 - (alpha * a),
                                     1.0 + (alpha / a),
                                     -2.0 * cos_w,
                                     1.0 - (alpha / a)
                                   ]
                                 when :lowshelf
                                   shelf_coefficients(:low, cos_w, sin_w, a)
                                 when :highshelf
                                   shelf_coefficients(:high, cos_w, sin_w, a)
                                 else
                                   raise InvalidParameterError, "unsupported filter type: #{@type}"
                                 end

        [
          b0 / a0,
          b1 / a0,
          b2 / a0,
          a1 / a0,
          a2 / a0
        ]
      end

      def shelf_coefficients(mode, cos_w, sin_w, a)
        sqrt_a = Math.sqrt(a)
        two_sqrt_a_alpha = 2.0 * sqrt_a * (sin_w / 2.0)
        if mode == :low
          [
            a * ((a + 1.0) - ((a - 1.0) * cos_w) + two_sqrt_a_alpha),
            2.0 * a * ((a - 1.0) - ((a + 1.0) * cos_w)),
            a * ((a + 1.0) - ((a - 1.0) * cos_w) - two_sqrt_a_alpha),
            (a + 1.0) + ((a - 1.0) * cos_w) + two_sqrt_a_alpha,
            -2.0 * ((a - 1.0) + ((a + 1.0) * cos_w)),
            (a + 1.0) + ((a - 1.0) * cos_w) - two_sqrt_a_alpha
          ]
        else
          [
            a * ((a + 1.0) + ((a - 1.0) * cos_w) + two_sqrt_a_alpha),
            -2.0 * a * ((a - 1.0) + ((a + 1.0) * cos_w)),
            a * ((a + 1.0) + ((a - 1.0) * cos_w) - two_sqrt_a_alpha),
            (a + 1.0) - ((a - 1.0) * cos_w) + two_sqrt_a_alpha,
            2.0 * ((a - 1.0) - ((a + 1.0) * cos_w)),
            (a + 1.0) - ((a - 1.0) * cos_w) - two_sqrt_a_alpha
          ]
        end
      end

      def validate_type!(type)
        value = type.to_sym
        supported = %i[lowpass highpass bandpass notch peaking lowshelf highshelf]
        raise InvalidParameterError, "unsupported filter type: #{type.inspect}" unless supported.include?(value)

        value
      rescue NoMethodError
        raise InvalidParameterError, "filter type must be Symbol/String: #{type.inspect}"
      end

      def validate_cutoff!(cutoff)
        unless cutoff.is_a?(Numeric) && cutoff.respond_to?(:finite?) && cutoff.finite? && cutoff.positive?
          raise InvalidParameterError, "cutoff must be a positive finite Numeric"
        end

        cutoff.to_f
      end

      def validate_q!(q)
        unless q.is_a?(Numeric) && q.respond_to?(:finite?) && q.finite? && q.positive?
          raise InvalidParameterError, "q must be a positive finite Numeric"
        end

        q.to_f
      end

      def validate_gain!(gain_db)
        unless gain_db.is_a?(Numeric) && gain_db.respond_to?(:finite?) && gain_db.finite?
          raise InvalidParameterError, "gain_db must be a finite Numeric"
        end

        gain_db.to_f
      end

      def validate_cutoff_below_nyquist!(sample_rate)
        nyquist = sample_rate / 2.0
        return if @cutoff < nyquist

        raise InvalidParameterError,
              "cutoff must be below Nyquist frequency (#{nyquist} Hz) for sample_rate #{sample_rate}"
      end
    end
  end
end
