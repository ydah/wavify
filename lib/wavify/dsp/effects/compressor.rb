# frozen_string_literal: true

module Wavify
  module DSP
    module Effects
      # Peak compressor with threshold, ratio, attack, and release controls.
      class Compressor < EffectBase
        def initialize(threshold: -10, ratio: 4, attack: 0.01, release: 0.1, makeup_gain: 0.0, knee: 0.0,
                       sidechain: nil)
          super()
          @threshold_db = validate_numeric!(threshold, :threshold).to_f
          @ratio = validate_ratio!(ratio)
          @attack = validate_time!(attack, :attack)
          @release = validate_time!(release, :release)
          @makeup_gain_db = validate_numeric!(makeup_gain, :makeup_gain).to_f
          @knee_db = validate_knee!(knee)
          @sidechain = validate_sidechain!(sidechain)
          reset
        end

        def process(buffer)
          raise InvalidParameterError, "buffer must be Core::SampleBuffer" unless buffer.is_a?(Core::SampleBuffer)

          float_format = buffer.format.with(sample_format: :float, bit_depth: 32)
          float_buffer = buffer.convert(float_format)
          detector = @sidechain ? @sidechain.convert(float_format) : float_buffer
          prepare_runtime_if_needed!(
            sample_rate: float_format.sample_rate,
            channels: float_buffer.format.channels
          )

          output = []
          float_buffer.samples.each_slice(@runtime_channels).with_index do |frame, frame_index|
            detector_level = detector_frame_level(detector, frame_index)
            gain = gain_for_detector_level(detector_level)
            output.concat(frame.map { |sample| (sample * gain).clamp(-1.0, 1.0) })
          end

          Core::SampleBuffer.new(output, float_format).convert(buffer.format)
        end

        # Processes a single sample for one channel.
        #
        # @param sample [Numeric]
        # @param channel [Integer]
        # @param sample_rate [Integer]
        # @return [Float]
        def process_sample(sample, channel:, sample_rate:)
          x = sample.to_f
          process_sample_with_level(x, x.abs, channel: channel, sample_rate: sample_rate)
        end

        private

        def process_sample_with_level(sample, level, channel:, sample_rate:)
          sample * gain_for_detector_level(level)
        end

        def gain_for_detector_level(level)
          envelope = @envelopes.fetch(0)
          coeff = level > envelope ? @attack_coefficient : @release_coefficient
          envelope += (1.0 - coeff) * (level - envelope)
          @envelopes[0] = envelope

          gain_for_envelope(envelope)
        end

        def prepare_runtime_state(sample_rate:, channels:)
          @envelopes = [0.0]
          @threshold_linear = 10.0**(@threshold_db / 20.0)
          @attack_coefficient = time_coefficient(@attack, sample_rate)
          @release_coefficient = time_coefficient(@release, sample_rate)
        end

        def reset_runtime_state
          @envelopes = []
          @threshold_linear = nil
          @attack_coefficient = nil
          @release_coefficient = nil
        end

        def gain_for_envelope(envelope)
          return makeup_gain if envelope <= 0.0

          input_db = 20.0 * Math.log10(envelope)
          gain_reduction_db = compression_gain_reduction_db(input_db)
          10.0**((gain_reduction_db + @makeup_gain_db) / 20.0)
        end

        def compression_gain_reduction_db(input_db)
          over_threshold = input_db - @threshold_db
          if @knee_db.positive?
            half_knee = @knee_db / 2.0
            return 0.0 if over_threshold <= -half_knee
            return hard_knee_gain_reduction_db(over_threshold) if over_threshold >= half_knee

            knee_position = over_threshold + half_knee
            ((1.0 / @ratio) - 1.0) * (knee_position * knee_position) / (2.0 * @knee_db)
          else
            hard_knee_gain_reduction_db(over_threshold)
          end
        end

        def hard_knee_gain_reduction_db(over_threshold)
          return 0.0 unless over_threshold.positive?

          (over_threshold / @ratio) - over_threshold
        end

        def makeup_gain
          10.0**(@makeup_gain_db / 20.0)
        end

        def time_coefficient(seconds, sample_rate)
          return 0.0 if seconds <= 0.0

          Math.exp(-1.0 / (seconds * sample_rate))
        end

        def validate_numeric!(value, name)
          raise InvalidParameterError, "#{name} must be a finite Numeric" unless value.is_a?(Numeric) && value.respond_to?(:finite?) && value.finite?

          value
        end

        def validate_ratio!(value)
          unless value.is_a?(Numeric) && value.respond_to?(:finite?) && value.finite? && value >= 1.0
            raise InvalidParameterError, "ratio must be a finite Numeric >= 1.0"
          end

          value.to_f
        end

        def validate_time!(value, name)
          unless value.is_a?(Numeric) && value.respond_to?(:finite?) && value.finite? && value >= 0.0
            raise InvalidParameterError, "#{name} must be a non-negative finite Numeric"
          end

          value.to_f
        end

        def validate_knee!(value)
          unless value.is_a?(Numeric) && value.respond_to?(:finite?) && value.finite? && value >= 0.0
            raise InvalidParameterError, "knee must be a non-negative finite Numeric"
          end

          value.to_f
        end

        def validate_sidechain!(value)
          return nil if value.nil?
          return value.buffer if defined?(Wavify::Audio) && value.is_a?(Wavify::Audio)
          return value if value.is_a?(Core::SampleBuffer)

          raise InvalidParameterError, "sidechain must be Audio or Core::SampleBuffer"
        end

        def detector_frame_level(detector, frame_index)
          start_index = frame_index * @runtime_channels
          frame = detector.samples.slice(start_index, @runtime_channels) || []
          frame.map(&:abs).max || 0.0
        end
      end
    end
  end
end
