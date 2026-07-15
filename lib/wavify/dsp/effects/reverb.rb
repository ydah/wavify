# frozen_string_literal: true

module Wavify
  module DSP
    module Effects
      # Lightweight Schroeder-style reverb effect.
      class Reverb < EffectBase
        COMB_TAPS_44K = [1116, 1188, 1277, 1356].freeze # :nodoc:
        ALLPASS_TAPS_44K = [556, 441].freeze # :nodoc:

        def initialize(room_size: 0.5, damping: 0.5, mix: 0.3, pre_delay: 0.0, width: 1.0)
          super()
          @room_size = validate_unit!(room_size, :room_size)
          @damping = validate_unit!(damping, :damping)
          @mix = validate_unit!(mix, :mix)
          @pre_delay = validate_time!(pre_delay, :pre_delay)
          @width = validate_width!(width)
          reset
        end

        # Processes a sample buffer.
        #
        # Stereo buffers apply `width:` to the wet signal before mixing it with
        # the dry input. Mono and multichannel buffers keep per-channel wet paths.
        #
        # @param buffer [Wavify::Core::SampleBuffer]
        # @return [Wavify::Core::SampleBuffer]
        def process(buffer)
          raise InvalidParameterError, "buffer must be Core::SampleBuffer" unless buffer.is_a?(Core::SampleBuffer)

          float_format = buffer.format.with(sample_format: :float, bit_depth: 32)
          float_buffer = buffer.convert(float_format)
          channels = float_buffer.format.channels
          prepare_runtime_if_needed!(sample_rate: float_format.sample_rate, channels: channels)

          output = Array.new(float_buffer.samples.length)
          float_buffer.samples.each_slice(channels).with_index do |frame, frame_index|
            wet_frame = frame.each_with_index.map do |sample, channel|
              wet_sample_for(@channels_state.fetch(channel), sample.to_f)
            end
            wet_frame = apply_stereo_width(wet_frame) if channels == 2

            base = frame_index * channels
            frame.each_with_index do |dry, channel|
              output[base + channel] = mix_dry_wet(dry.to_f, wet_frame.fetch(channel))
            end
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
          dry = sample.to_f
          channel_state = @channels_state.fetch(channel)
          mix_dry_wet(dry, wet_sample_for(channel_state, dry))
        end

        # @return [Float] estimated reverb tail duration in seconds
        def tail_duration
          return 0.0 if @mix.zero?

          @pre_delay + 0.25 + (@room_size * 2.5)
        end

        private

        def prepare_runtime_state(sample_rate:, channels:)
          scale = sample_rate.to_f / 44_100.0
          comb_feedback = 0.6 + (@room_size * 0.34)
          damping = @damping

          @input_gain = 0.35
          pre_delay_frames = (@pre_delay * sample_rate).round
          @channels_state = Array.new(channels) do
            combs = COMB_TAPS_44K.map do |tap|
              length = [(tap * scale).round, 8].max
              {
                buffer: Array.new(length, 0.0),
                index: 0,
                feedback: comb_feedback,
                damping: damping,
                filter_store: 0.0
              }
            end
            allpasses = ALLPASS_TAPS_44K.map do |tap|
              length = [(tap * scale).round, 4].max
              {
                buffer: Array.new(length, 0.0),
                index: 0,
                feedback: 0.5
              }
            end
            {
              combs: combs,
              allpasses: allpasses,
              pre_delay_buffer: Array.new(pre_delay_frames, 0.0),
              pre_delay_index: 0
            }
          end
        end

        def reset_runtime_state
          @channels_state = []
          @input_gain = nil
        end

        def pre_delay_sample(channel_state, input_sample)
          buffer = channel_state[:pre_delay_buffer]
          return input_sample if buffer.empty?

          index = channel_state[:pre_delay_index]
          delayed = buffer[index]
          buffer[index] = input_sample
          channel_state[:pre_delay_index] = (index + 1) % buffer.length
          delayed
        end

        def wet_sample_for(channel_state, dry)
          comb_input = pre_delay_sample(channel_state, dry) * @input_gain
          comb_sum = 0.0
          channel_state[:combs].each do |comb|
            comb_sum += process_comb(comb, comb_input)
          end

          wet = comb_sum / channel_state[:combs].length
          channel_state[:allpasses].each do |allpass|
            wet = process_allpass(allpass, wet)
          end
          wet
        end

        def apply_stereo_width(wet_frame)
          left, right = wet_frame
          mid = (left + right) * 0.5
          side = ((left - right) * 0.5) * @width
          [mid + side, mid - side]
        end

        def mix_dry_wet(dry, wet)
          (dry * (1.0 - @mix)) + (wet * @mix)
        end

        def process_comb(comb, input_sample)
          buffer = comb[:buffer]
          index = comb[:index]
          delayed = buffer[index]

          filter_store = (delayed * (1.0 - comb[:damping])) + (comb[:filter_store] * comb[:damping])
          comb[:filter_store] = filter_store
          buffer[index] = input_sample + (filter_store * comb[:feedback])
          comb[:index] = (index + 1) % buffer.length

          delayed
        end

        def process_allpass(allpass, input_sample)
          buffer = allpass[:buffer]
          index = allpass[:index]
          delayed = buffer[index]

          output = delayed - input_sample
          buffer[index] = input_sample + (delayed * allpass[:feedback])
          allpass[:index] = (index + 1) % buffer.length

          output
        end

        def validate_unit!(value, name)
          raise InvalidParameterError, "#{name} must be Numeric in 0.0..1.0" unless value.is_a?(Numeric) && value.between?(0.0, 1.0)

          value.to_f
        end

        def validate_time!(value, name)
          unless value.is_a?(Numeric) && value.respond_to?(:finite?) && value.finite? && value >= 0.0
            raise InvalidParameterError, "#{name} must be a non-negative finite Numeric"
          end

          value.to_f
        end

        def validate_width!(value)
          unless value.is_a?(Numeric) && value.respond_to?(:finite?) && value.finite? && value.between?(0.0, 2.0)
            raise InvalidParameterError, "width must be a finite Numeric in 0.0..2.0"
          end

          value.to_f
        end
      end
    end
  end
end
