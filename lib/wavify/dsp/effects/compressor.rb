# frozen_string_literal: true

module Wavify
  module DSP
    module Effects
      # Peak compressor with threshold, ratio, attack, and release controls.
      class Compressor < EffectBase
        def initialize(threshold: -10, ratio: 4, attack: 0.01, release: 0.1, makeup_gain: 0.0, knee: 0.0,
                       sidechain: nil, sidechain_end: :silence)
          super()
          @threshold_db = validate_numeric!(threshold, :threshold).to_f
          @ratio = validate_ratio!(ratio)
          @attack = validate_time!(attack, :attack)
          @release = validate_time!(release, :release)
          @makeup_gain_db = validate_numeric!(makeup_gain, :makeup_gain).to_f
          @knee_db = validate_knee!(knee)
          @sidechain = validate_sidechain!(sidechain)
          @sidechain_end = validate_sidechain_end!(sidechain_end)
          reset
        end

        def process(buffer)
          raise InvalidParameterError, "buffer must be Core::SampleBuffer" unless buffer.is_a?(Core::SampleBuffer)

          float_format = buffer.format.with(sample_format: :float, bit_depth: 32)
          float_buffer = buffer.convert(float_format)
          prepare_runtime_if_needed!(
            sample_rate: float_format.sample_rate,
            channels: float_buffer.format.channels
          )

          output = []
          float_buffer.samples.each_slice(@runtime_channels) do |frame|
            detector_level = @sidechain ? next_sidechain_level : frame.map(&:abs).max
            gain = gain_for_detector_level(detector_level)
            output.concat(frame.map { |sample| sample * gain })
          end

          Core::SampleBuffer.new(output, float_format).convert(buffer.format)
        end

        # Compression requires a complete frame so the detector can remain
        # stereo-linked. Use #process with a SampleBuffer.
        #
        # @param sample [Numeric]
        # @param channel [Integer]
        # @param sample_rate [Integer]
        # @return [Float]
        def process_sample(sample, channel:, sample_rate:)
          raise NotImplementedError, "Compressor requires frame-aware #apply or #process"
        end

        private

        def gain_for_detector_level(level)
          coeff = level > @envelope ? @attack_coefficient : @release_coefficient
          @envelope += (1.0 - coeff) * (level - @envelope)

          gain_for_envelope(@envelope)
        end

        def prepare_runtime_state(sample_rate:, channels:)
          @envelope = 0.0
          @threshold_linear = 10.0**(@threshold_db / 20.0)
          @attack_coefficient = time_coefficient(@attack, sample_rate)
          @release_coefficient = time_coefficient(@release, sample_rate)
          @sidechain_cursor = 0
          @sidechain_runtime = if @sidechain
                                 format = Core::Format.new(
                                   channels: channels,
                                   sample_rate: sample_rate,
                                   bit_depth: 32,
                                   sample_format: :float
                                 )
                                 @sidechain.convert(format)
                               end
        end

        def reset_runtime_state
          @envelope = 0.0
          @threshold_linear = nil
          @attack_coefficient = nil
          @release_coefficient = nil
          @sidechain_cursor = 0
          @sidechain_runtime = nil
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

        def validate_sidechain_end!(value)
          normalized = value.to_sym if value.respond_to?(:to_sym)
          return normalized if %i[silence hold loop].include?(normalized)

          raise InvalidParameterError, "sidechain_end must be :silence, :hold, or :loop"
        end

        def next_sidechain_level
          frame_count = @sidechain_runtime.sample_frame_count
          frame_index = sidechain_frame_index(frame_count)
          @sidechain_cursor += 1
          return 0.0 unless frame_index

          start_index = frame_index * @runtime_channels
          frame = @sidechain_runtime.samples.slice(start_index, @runtime_channels) || []
          frame.map(&:abs).max || 0.0
        end

        def sidechain_frame_index(frame_count)
          return nil if frame_count.zero?
          return @sidechain_cursor if @sidechain_cursor < frame_count

          case @sidechain_end
          when :silence then nil
          when :hold then frame_count - 1
          when :loop then @sidechain_cursor % frame_count
          end
        end
      end
    end
  end
end
