# frozen_string_literal: true

module Wavify
  module DSP
    # ITU-R BS.1770 integrated loudness meter with EBU-style gating.
    class LoudnessMeter
      LOUDNESS_OFFSET = -0.691
      ABSOLUTE_GATE_LUFS = -70.0
      RELATIVE_GATE_LU = -10.0
      BLOCK_SECONDS = 0.4
      STEP_SECONDS = 0.1
      SHORT_TERM_SECONDS = 3.0
      TRUE_PEAK_OVERSAMPLING = 4
      TRUE_PEAK_RADIUS = 8

      class << self
        # Measures integrated loudness. Inputs shorter than the BS.1770 400 ms
        # block are treated as a single partial block.
        def integrated(samples, sample_rate: nil, channels: nil, format: nil, channel_layout: nil)
          samples, sample_rate, channels, channel_layout = measurement_input(
            samples,
            sample_rate: sample_rate,
            channels: channels,
            format: format,
            channel_layout: channel_layout
          )
          return -Float::INFINITY if samples.empty?

          weighted = k_weight(samples, sample_rate: sample_rate, channels: channels)
          energies = block_energies(
            weighted,
            sample_rate: sample_rate,
            channels: channels,
            channel_layout: channel_layout
          )
          absolute_gated = energies.select { |energy| loudness_for_energy(energy) >= ABSOLUTE_GATE_LUFS }
          return -Float::INFINITY if absolute_gated.empty?

          relative_gate = loudness_for_energy(mean(absolute_gated)) + RELATIVE_GATE_LU
          relative_gated = absolute_gated.select { |energy| loudness_for_energy(energy) >= relative_gate }
          loudness_for_energy(mean(relative_gated))
        end

        # Measures the most recent 400 ms loudness window without gating.
        def momentary(samples, sample_rate: nil, channels: nil, format: nil, channel_layout: nil)
          window_loudness(
            samples,
            seconds: BLOCK_SECONDS,
            sample_rate: sample_rate,
            channels: channels,
            format: format,
            channel_layout: channel_layout
          )
        end

        # Measures the most recent 3 second loudness window without gating.
        def short_term(samples, sample_rate: nil, channels: nil, format: nil, channel_layout: nil)
          window_loudness(
            samples,
            seconds: SHORT_TERM_SECONDS,
            sample_rate: sample_rate,
            channels: channels,
            format: format,
            channel_layout: channel_layout
          )
        end

        # Estimates inter-sample true peak with windowed-sinc oversampling.
        def true_peak(samples, sample_rate: nil, channels: nil, format: nil, oversampling: TRUE_PEAK_OVERSAMPLING)
          samples, _sample_rate, channels, = measurement_input(
            samples,
            sample_rate: sample_rate,
            channels: channels,
            format: format,
            channel_layout: nil
          )
          unless [2, 4, 8].include?(oversampling)
            raise InvalidParameterError, "oversampling must be 2, 4, or 8"
          end
          return 0.0 if samples.empty?

          channel_samples = Array.new(channels) { [] }
          samples.each_with_index { |sample, index| channel_samples.fetch(index % channels) << sample.to_f }
          channel_samples.map { |values| oversampled_peak(values, oversampling) }.max || 0.0
        end

        private

        def measurement_input(samples, sample_rate:, channels:, format:, channel_layout:)
          if samples.is_a?(Core::SampleBuffer)
            format ||= samples.format
            float_format = samples.format.with(sample_format: :float, bit_depth: 32)
            samples = (samples.format == float_format ? samples : samples.convert(float_format)).samples
          end
          if format
            raise InvalidParameterError, "format must be Core::Format" unless format.is_a?(Core::Format)

            sample_rate ||= format.sample_rate
            channels ||= format.channels
            channel_layout ||= format.channel_layout
          end
          unless samples.is_a?(Array) && samples.all? { |sample| sample.is_a?(Numeric) && sample.respond_to?(:finite?) && sample.finite? }
            raise InvalidParameterError, "samples must be an Array of finite Numeric values"
          end
          unless sample_rate.is_a?(Integer) && sample_rate.positive?
            raise InvalidParameterError, "sample_rate must be a positive Integer"
          end
          unless channels.is_a?(Integer) && channels.positive? && (samples.length % channels).zero?
            raise InvalidParameterError, "channels must be a positive Integer that divides the sample count"
          end
          if channel_layout && (!channel_layout.is_a?(Array) || channel_layout.length != channels)
            raise InvalidParameterError, "channel_layout must contain one position per channel"
          end

          [samples, sample_rate, channels, channel_layout]
        end

        def window_loudness(samples, seconds:, sample_rate:, channels:, format:, channel_layout:)
          samples, sample_rate, channels, channel_layout = measurement_input(
            samples,
            sample_rate: sample_rate,
            channels: channels,
            format: format,
            channel_layout: channel_layout
          )
          return -Float::INFINITY if samples.empty?

          frames = [samples.length / channels, (seconds * sample_rate).round].min
          window = samples.last(frames * channels)
          weighted = k_weight(window, sample_rate: sample_rate, channels: channels)
          energy = block_energy(weighted, channels: channels, channel_layout: channel_layout)
          loudness_for_energy(energy)
        end

        def k_weight(samples, sample_rate:, channels:)
          shelf = high_shelf_coefficients(sample_rate)
          highpass = highpass_coefficients(sample_rate)
          apply_biquad(apply_biquad(samples, shelf, channels), highpass, channels)
        end

        def high_shelf_coefficients(sample_rate)
          frequency = 1_681.974_450_955_533
          gain_db = 3.999_843_853_973_347
          q = 0.707_175_236_955_419_6
          k = Math.tan(Math::PI * frequency / sample_rate)
          high_gain = 10.0**(gain_db / 20.0)
          band_gain = high_gain**0.499_666_774_154_541_6
          a0 = 1.0 + (k / q) + (k * k)

          [
            (high_gain + (band_gain * k / q) + (k * k)) / a0,
            2.0 * ((k * k) - high_gain) / a0,
            (high_gain - (band_gain * k / q) + (k * k)) / a0,
            2.0 * ((k * k) - 1.0) / a0,
            (1.0 - (k / q) + (k * k)) / a0
          ]
        end

        def highpass_coefficients(sample_rate)
          frequency = 38.135_470_876_024_44
          q = 0.500_327_037_323_877_3
          k = Math.tan(Math::PI * frequency / sample_rate)
          a0 = 1.0 + (k / q) + (k * k)

          [
            1.0,
            -2.0,
            1.0,
            2.0 * ((k * k) - 1.0) / a0,
            (1.0 - (k / q) + (k * k)) / a0
          ]
        end

        def apply_biquad(samples, coefficients, channels)
          b0, b1, b2, a1, a2 = coefficients
          x1 = Array.new(channels, 0.0)
          x2 = Array.new(channels, 0.0)
          y1 = Array.new(channels, 0.0)
          y2 = Array.new(channels, 0.0)
          output = Array.new(samples.length)
          samples.each_with_index do |sample, index|
            channel = index % channels
            value = (b0 * sample) + (b1 * x1.fetch(channel)) + (b2 * x2.fetch(channel)) -
                    (a1 * y1.fetch(channel)) - (a2 * y2.fetch(channel))
            x2[channel] = x1.fetch(channel)
            x1[channel] = sample
            y2[channel] = y1.fetch(channel)
            y1[channel] = value
            output[index] = value
          end
          output
        end

        def block_energies(samples, sample_rate:, channels:, channel_layout:)
          frame_count = samples.length / channels
          block_frames = [(BLOCK_SECONDS * sample_rate).round, frame_count].min
          step_frames = [(STEP_SECONDS * sample_rate).round, 1].max
          starts = frame_count <= block_frames ? [0] : (0..(frame_count - block_frames)).step(step_frames)
          gains = channel_gains(channels, channel_layout)

          starts.map do |start_frame|
            channel_squares = Array.new(channels, 0.0)
            start_index = start_frame * channels
            end_index = start_index + (block_frames * channels)
            samples[start_index...end_index].each_with_index do |sample, index|
              channel_squares[index % channels] += sample * sample
            end
            channel_squares.each_with_index.sum do |square_sum, channel|
              gains.fetch(channel) * square_sum / block_frames
            end
          end
        end

        def block_energy(samples, channels:, channel_layout:)
          frames = samples.length / channels
          return 0.0 if frames.zero?

          squares = Array.new(channels, 0.0)
          samples.each_with_index { |sample, index| squares[index % channels] += sample * sample }
          gains = channel_gains(channels, channel_layout)
          squares.each_with_index.sum { |sum, channel| gains.fetch(channel) * sum / frames }
        end

        def channel_gains(channels, channel_layout)
          layout = channel_layout || Core::Format::DEFAULT_CHANNEL_LAYOUTS[channels]
          return Array.new(channels, 1.0) unless layout

          layout.map do |position|
            case position.to_sym
            when :low_frequency then 0.0
            when :back_left, :back_right, :back_center, :side_left, :side_right then 1.41
            else 1.0
            end
          end
        end

        def oversampled_peak(samples, factor)
          peak = samples.map(&:abs).max || 0.0
          return peak if samples.length < 2

          (0...(samples.length - 1)).each do |index|
            1.upto(factor - 1) do |step|
              time = index + (step.to_f / factor)
              peak = [peak, sinc_interpolate(samples, time).abs].max
            end
          end
          peak
        end

        def sinc_interpolate(samples, time)
          center = time.floor
          start_index = [center - TRUE_PEAK_RADIUS + 1, 0].max
          end_index = [center + TRUE_PEAK_RADIUS, samples.length - 1].min
          weighted_sum = 0.0
          weight_sum = 0.0
          start_index.upto(end_index) do |index|
            distance = time - index
            next if distance.abs >= TRUE_PEAK_RADIUS

            sinc = distance.zero? ? 1.0 : Math.sin(Math::PI * distance) / (Math::PI * distance)
            window = 0.5 * (1.0 + Math.cos(Math::PI * distance / TRUE_PEAK_RADIUS))
            weight = sinc * window
            weighted_sum += samples.fetch(index) * weight
            weight_sum += weight
          end
          weight_sum.zero? ? 0.0 : weighted_sum / weight_sum
        end

        def loudness_for_energy(energy)
          return -Float::INFINITY unless energy.positive?

          LOUDNESS_OFFSET + (10.0 * Math.log10(energy))
        end

        def mean(values)
          values.sum / values.length.to_f
        end
      end
    end
  end
end
