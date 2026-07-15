# frozen_string_literal: true

module Wavify
  module DSP
    module Effects
      # Stereo-linked lookahead peak limiter with attack and release smoothing.
      class Limiter < EffectBase
        # FIFO with an amortized O(1) maximum for streaming lookahead detection.
        class LookaheadQueue
          def initialize
            @incoming = []
            @outgoing = []
          end

          def push(frame, peak)
            maximum = [peak, @incoming.last&.fetch(2) || 0.0].max
            @incoming << [frame, peak, maximum]
          end

          def shift
            refill_outgoing if @outgoing.empty?
            entry = @outgoing.pop
            [entry.fetch(0), entry.fetch(1)]
          end

          def maximum
            [@incoming.last&.fetch(2) || 0.0, @outgoing.last&.fetch(2) || 0.0].max
          end

          def length
            @incoming.length + @outgoing.length
          end

          def empty?
            @incoming.empty? && @outgoing.empty?
          end

          private

          def refill_outgoing
            until @incoming.empty?
              frame, peak = @incoming.pop.first(2)
              maximum = [peak, @outgoing.last&.fetch(2) || 0.0].max
              @outgoing << [frame, peak, maximum]
            end
          end
        end
        private_constant :LookaheadQueue

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
            delayed_frame = frame.map { |sample| sample * @input_gain }
            @delay_frames.push(delayed_frame, frame_peak(delayed_frame))
            if @delay_frames.length <= @lookahead_frames
              output.concat(Array.new(@runtime_channels, 0.0))
              update_gain(@delay_frames.maximum)
              next
            end

            delayed_frame, delayed_peak = @delay_frames.shift
            output.concat(limit_frame(delayed_frame, @delay_frames.maximum, current_peak: delayed_peak))
          end
          Core::SampleBuffer.new(output, float_format).convert(buffer.format)
        end

        # Emits samples retained by the lookahead delay.
        def flush(format: nil)
          return nil unless runtime_prepared? && @delay_frames && !@delay_frames.empty?

          runtime_format = Core::Format.new(
            channels: @runtime_channels,
            sample_rate: @runtime_sample_rate,
            bit_depth: 32,
            sample_format: :float
          )
          output = []
          until @delay_frames.empty?
            delayed_frame, delayed_peak = @delay_frames.shift
            output.concat(limit_frame(delayed_frame, @delay_frames.maximum, current_peak: delayed_peak))
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

        def process_sample(_sample, channel:, sample_rate:)
          raise NotImplementedError, "Limiter requires frame-aware #apply or #process"
        end

        private

        def limit_offline_frames(frames)
          return [] if frames.empty?

          peaks = frames.map { |frame| frame_peak(frame) }
          pre_roll_gain(peaks)
          future_peaks = sliding_window_maxima(peaks, @lookahead_frames + 1)
          frames.each_index.map do |index|
            limit_frame(frames.fetch(index), future_peaks.fetch(index), current_peak: peaks.fetch(index))
          end
        end

        def pre_roll_gain(peaks)
          peak = 0.0
          @lookahead_frames.times do |index|
            peak = [peak, peaks.fetch([index, peaks.length - 1].min)].max
            update_gain(peak)
          end
        end

        def sliding_window_maxima(peaks, window_size)
          maxima = Array.new(peaks.length)
          deque = []
          head = 0
          right = -1

          peaks.each_index do |left|
            desired_right = [left + window_size - 1, peaks.length - 1].min
            while right < desired_right
              right += 1
              deque.pop while deque.length > head && peaks.fetch(deque.last) <= peaks.fetch(right)
              deque << right
            end
            head += 1 while deque.fetch(head) < left
            maxima[left] = peaks.fetch(deque.fetch(head))
          end
          maxima
        end

        def limit_frame(frame, peak, current_peak: frame_peak(frame))
          smoothed_gain = update_gain(peak)
          required_gain = current_peak.positive? ? [@ceiling / current_peak, 1.0].min : 1.0
          applied_gain = [smoothed_gain, required_gain].min
          frame.map { |sample| (sample * applied_gain).clamp(-@ceiling, @ceiling) }
        end

        def update_gain(peak)
          target = peak > @ceiling ? @ceiling / peak : 1.0
          coefficient = target < @gain ? @attack_coefficient : @release_coefficient
          @gain = target + (coefficient * (@gain - target))
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
          @delay_frames = LookaheadQueue.new
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
