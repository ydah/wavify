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

      class << self
        # Measures integrated loudness. Inputs shorter than the BS.1770 400 ms
        # block are treated as a single partial block.
        def integrated(samples, sample_rate:, channels:)
          return -Float::INFINITY if samples.empty?

          weighted = k_weight(samples, sample_rate: sample_rate, channels: channels)
          energies = block_energies(weighted, sample_rate: sample_rate, channels: channels)
          absolute_gated = energies.select { |energy| loudness_for_energy(energy) >= ABSOLUTE_GATE_LUFS }
          return -Float::INFINITY if absolute_gated.empty?

          relative_gate = loudness_for_energy(mean(absolute_gated)) + RELATIVE_GATE_LU
          relative_gated = absolute_gated.select { |energy| loudness_for_energy(energy) >= relative_gate }
          loudness_for_energy(mean(relative_gated))
        end

        private

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

        def block_energies(samples, sample_rate:, channels:)
          frame_count = samples.length / channels
          block_frames = [(BLOCK_SECONDS * sample_rate).round, frame_count].min
          step_frames = [(STEP_SECONDS * sample_rate).round, 1].max
          starts = frame_count <= block_frames ? [0] : (0..(frame_count - block_frames)).step(step_frames)
          gains = channel_gains(channels)

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

        def channel_gains(channels)
          # Wavify channel order: L, R, C, LFE, Ls, Rs. BS.1770 excludes LFE
          # and applies +1.5 dB to surround channels.
          [1.0, 1.0, 1.0, 0.0, 1.41, 1.41].first(channels).tap do |gains|
            gains.concat(Array.new(channels - gains.length, 1.0))
          end
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
