# frozen_string_literal: true

module Wavify
  module DSP
    module Effects
      # Mid/side stereo width processor.
      class StereoWidener
        def initialize(width: 1.25)
          @width = validate_width!(width)
        end

        # Applies mid/side width adjustment to a stereo buffer.
        #
        # @param buffer [Wavify::Core::SampleBuffer]
        # @return [Wavify::Core::SampleBuffer]
        def process(buffer)
          raise InvalidParameterError, "buffer must be Core::SampleBuffer" unless buffer.is_a?(Core::SampleBuffer)
          raise InvalidParameterError, "StereoWidener requires stereo input" unless buffer.format.channels == 2

          float_format = buffer.format.with(sample_format: :float, bit_depth: 32)
          float_buffer = buffer.convert(float_format)
          widened = float_buffer.samples.each_slice(2).flat_map do |left, right|
            mid = (left + right) / 2.0
            side = ((left - right) / 2.0) * @width
            [mid + side, mid - side]
          end

          Wavify::Core::SampleBuffer.new(widened, float_format).convert(buffer.format)
        end

        def apply(buffer)
          DSP::Processor.render(self, buffer)
        end

        def build_runtime
          dup.reset
        end

        # Stateless processor API compatibility.
        #
        # @return [StereoWidener] self
        def reset
          self
        end

        # @return [Float]
        def latency
          0.0
        end

        # @return [Float]
        def lookahead
          0.0
        end

        # @return [Float]
        def tail_duration
          0.0
        end

        private

        def validate_width!(value)
          unless value.is_a?(Numeric) && value.respond_to?(:finite?) && value.finite? && value >= 0.0
            raise InvalidParameterError, "width must be a non-negative finite Numeric"
          end

          value.to_f
        end
      end
    end
  end
end
