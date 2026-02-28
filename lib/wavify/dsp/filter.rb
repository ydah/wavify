# frozen_string_literal: true

module Wavify
  # Digital signal processing primitives.
  module DSP
    # Stateful biquad filter with common factory constructors.
    class Filter
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

      def self.bandpass(center:, bandwidth:)
        raise InvalidParameterError, "bandwidth must be positive" unless bandwidth.is_a?(Numeric) && bandwidth.positive?

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

      # Clears internal filter state for all channels.
      #
      # @return [void]
      def reset
        @channel_states = []
      end

      private

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
        raise InvalidParameterError, "cutoff must be a positive Numeric" unless cutoff.is_a?(Numeric) && cutoff.positive?

        cutoff.to_f
      end

      def validate_q!(q)
        raise InvalidParameterError, "q must be a positive Numeric" unless q.is_a?(Numeric) && q.positive?

        q.to_f
      end

      def validate_gain!(gain_db)
        raise InvalidParameterError, "gain_db must be Numeric" unless gain_db.is_a?(Numeric)

        gain_db.to_f
      end
    end
  end
end
