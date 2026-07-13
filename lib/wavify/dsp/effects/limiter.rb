# frozen_string_literal: true

module Wavify
  module DSP
    module Effects
      # Stereo-linked lookahead peak limiter with attack and release smoothing.
      class Limiter < EffectBase
        def initialize(ceiling: -1.0, input_gain: 0.0, attack: 0.001, release: 0.05, lookahead: 0.005)
          super()
          @ceiling_db = validate_dbfs!(ceiling, :ceiling)
          @input_gain_db = validate_finite_numeric!(input_gain, :input_gain).to_f
          @attack = validate_time!(attack, :attack)
          @release = validate_time!(release, :release)
          @lookahead = validate_time!(lookahead, :lookahead)
          @ceiling = db_to_amplitude(@ceiling_db)
          @input_gain = db_to_amplitude(@input_gain_db)
          reset
        end

        # Applies the limiter offline without adding latency to the result.
        def apply(buffer)
          raise InvalidParameterError, "buffer must be Core::SampleBuffer" unless buffer.is_a?(Core::SampleBuffer)

          float_format = buffer.format.with(sample_format: :float, bit_depth: 32)
          float_buffer = buffer.convert(float_format)
          prepare_runtime_if_needed!(sample_rate: float_format.sample_rate, channels: float_format.channels)
          reset_limiter_state

          frames = float_buffer.samples.each_slice(float_format.channels).map do |frame|
            frame.map { |sample| sample * @input_gain }
          end
          output = limit_offline_frames(frames).flatten(1)
          Core::SampleBuffer.new(output, float_format).convert(buffer.format)
        end

        # Processes a streaming chunk while preserving a lookahead delay.
        def process(buffer)
          raise InvalidParameterError, "buffer must be Core::SampleBuffer" unless buffer.is_a?(Core::SampleBuffer)

          float_format = buffer.format.with(sample_format: :float, bit_depth: 32)
          float_buffer = buffer.convert(float_format)
          prepare_runtime_if_needed!(sample_rate: float_format.sample_rate, channels: float_format.channels)

          output = []
          float_buffer.samples.each_slice(@runtime_channels) do |frame|
            @delay_frames << frame.map { |sample| sample * @input_gain }
            if @delay_frames.length <= @lookahead_frames
              output.concat(Array.new(@runtime_channels, 0.0))
              update_gain(detector_peak(@delay_frames))
              next
            end

            output.concat(limit_frame(@delay_frames.shift, detector_peak(@delay_frames)))
          end
          Core::SampleBuffer.new(output, float_format).convert(buffer.format)
        end

        # Emits samples retained by the lookahead delay.
        def flush(format: nil)
          return nil unless runtime_prepared? && @delay_frames&.any?

          runtime_format = Core::Format.new(
            channels: @runtime_channels,
            sample_rate: @runtime_sample_rate,
            bit_depth: 32,
            sample_format: :float
          )
          output = []
          until @delay_frames.empty?
            output.concat(limit_frame(@delay_frames.shift, detector_peak(@delay_frames)))
          end
          target_format = format || runtime_format
          Core::SampleBuffer.new(output, runtime_format).convert(target_format)
        end

        def latency
          @lookahead
        end

        def lookahead
          @lookahead
        end

        def tail_duration
          @lookahead
        end

        def process_sample(sample, channel:, sample_rate:)
          (sample.to_f * @input_gain).clamp(-@ceiling, @ceiling)
        end

        private

        def limit_offline_frames(frames)
          return [] if frames.empty?

          pre_roll_gain(frames)
          frames.each_index.map do |index|
            future = frames[index, @lookahead_frames + 1]
            limit_frame(frames.fetch(index), detector_peak(future))
          end
        end

        def pre_roll_gain(frames)
          @lookahead_frames.times do |index|
            update_gain(detector_peak(frames.first(index + 1)))
          end
        end

        def limit_frame(frame, peak)
          smoothed_gain = update_gain(peak)
          required_gain = frame_peak(frame).positive? ? [@ceiling / frame_peak(frame), 1.0].min : 1.0
          applied_gain = [smoothed_gain, required_gain].min
          frame.map { |sample| (sample * applied_gain).clamp(-@ceiling, @ceiling) }
        end

        def update_gain(peak)
          target = peak > @ceiling ? @ceiling / peak : 1.0
          coefficient = target < @gain ? @attack_coefficient : @release_coefficient
          @gain = target + (coefficient * (@gain - target))
        end

        def detector_peak(frames)
          frames.reduce(0.0) { |peak, frame| [peak, frame_peak(frame)].max }
        end

        def frame_peak(frame)
          frame.reduce(0.0) { |peak, sample| [peak, sample.abs].max }
        end

        def prepare_runtime_state(sample_rate:, channels:)
          @lookahead_frames = (@lookahead * sample_rate).round
          @attack_coefficient = time_coefficient(@attack, sample_rate)
          @release_coefficient = time_coefficient(@release, sample_rate)
          reset_limiter_state
        end

        def reset_runtime_state
          @lookahead_frames = 0
          @attack_coefficient = nil
          @release_coefficient = nil
          reset_limiter_state
        end

        def reset_limiter_state
          @delay_frames = []
          @gain = 1.0
        end

        def time_coefficient(seconds, sample_rate)
          return 0.0 if seconds.zero?

          Math.exp(-1.0 / (seconds * sample_rate))
        end

        def validate_dbfs!(value, name)
          numeric = validate_finite_numeric!(value, name)
          raise InvalidParameterError, "#{name} must be <= 0 dBFS" if numeric.positive?

          numeric.to_f
        end

        def validate_time!(value, name)
          numeric = validate_finite_numeric!(value, name)
          raise InvalidParameterError, "#{name} must be non-negative" if numeric.negative?

          numeric.to_f
        end

        def validate_finite_numeric!(value, name)
          unless value.is_a?(Numeric) && value.respond_to?(:finite?) && value.finite?
            raise InvalidParameterError, "#{name} must be a finite Numeric"
          end

          value
        end

        def db_to_amplitude(db)
          10.0**(db / 20.0)
        end
      end
    end
  end
end
