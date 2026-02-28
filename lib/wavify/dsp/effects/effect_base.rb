# frozen_string_literal: true

module Wavify
  module DSP
    module Effects
      # Base class for sample-by-sample effects with runtime channel state.
      class EffectBase
        # Applies the effect to a sample buffer.
        #
        # @param buffer [Wavify::Core::SampleBuffer]
        # @return [Wavify::Core::SampleBuffer]
        def apply(buffer)
          process(buffer)
        end

        def process(buffer)
          raise InvalidParameterError, "buffer must be Core::SampleBuffer" unless buffer.is_a?(Core::SampleBuffer)

          float_format = buffer.format.with(sample_format: :float, bit_depth: 32)
          float_buffer = buffer.convert(float_format)

          prepare_runtime_if_needed!(
            sample_rate: float_format.sample_rate,
            channels: float_buffer.format.channels
          )

          output = Array.new(float_buffer.samples.length)
          float_buffer.samples.each_with_index do |sample, sample_index|
            channel = sample_index % @runtime_channels
            output[sample_index] = process_sample(sample, channel: channel, sample_rate: @runtime_sample_rate).clamp(-1.0, 1.0)
          end

          Core::SampleBuffer.new(output, float_format).convert(buffer.format)
        end

        def process_sample(_sample, channel:, sample_rate:)
          raise NotImplementedError
        end

        # Resets runtime state and cached channel/sample-rate information.
        #
        # @return [EffectBase] self
        def reset
          @runtime_sample_rate = nil
          @runtime_channels = nil
          reset_runtime_state
          self
        end

        private

        def prepare_runtime_if_needed!(sample_rate:, channels:)
          return if @runtime_sample_rate == sample_rate && @runtime_channels == channels

          @runtime_sample_rate = sample_rate
          @runtime_channels = channels
          reset_runtime_state
          prepare_runtime_state(sample_rate: sample_rate, channels: channels)
        end

        def prepare_runtime_state(sample_rate:, channels:); end

        def reset_runtime_state; end

      end
    end
  end
end
