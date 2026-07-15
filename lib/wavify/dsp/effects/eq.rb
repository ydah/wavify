# frozen_string_literal: true

require_relative "../filter"

module Wavify
  module DSP
    module Effects
      # Ordered chain of biquad filters for simple EQ curves.
      class EQ
        def initialize(*filters)
          @filters = filters.flatten
          raise InvalidParameterError, "at least one filter is required" if @filters.empty?

          @filters.each do |filter|
            raise InvalidParameterError, "filters must respond to :apply or :process" unless filter.respond_to?(:apply) || filter.respond_to?(:process)
          end
          @runtime_format = nil
        end

        # Convenience constructor for common tone-shaping bands.
        #
        # @param highpass [Numeric, nil]
        # @param lowpass [Numeric, nil]
        # @param presence [Hash, nil] `{ cutoff:, q:, gain_db: }`
        # @return [EQ]
        def self.simple(highpass: nil, lowpass: nil, presence: nil)
          filters = []
          filters << Wavify::DSP::Filter.highpass(cutoff: highpass) if highpass
          filters << Wavify::DSP::Filter.lowpass(cutoff: lowpass) if lowpass
          filters << Wavify::DSP::Filter.peaking(**presence) if presence
          new(filters)
        end

        # Applies all filters in order.
        #
        # @param buffer [Wavify::Core::SampleBuffer]
        # @return [Wavify::Core::SampleBuffer]
        def process(buffer)
          raise InvalidParameterError, "buffer must be Core::SampleBuffer" unless buffer.is_a?(Core::SampleBuffer)

          original_format = buffer.format
          float_format = original_format.with(sample_format: :float, bit_depth: 32)
          processed = @filters.reduce(buffer.convert(float_format)) do |current, filter|
            DSP::Processor.process(filter, current)
          end.convert(original_format)
          @runtime_format = buffer.format
          processed
        end

        def apply(buffer)
          DSP::Processor.render(self, buffer)
        end

        # Resets stateful filters in the chain.
        #
        # @return [EQ] self
        def reset
          @filters.each { |filter| filter.reset if filter.respond_to?(:reset) }
          @runtime_format = nil
          self
        end

        def build_runtime
          self.class.new(@filters.map { |filter| DSP::Processor.build_runtime(filter) })
        end

        # Drains the filters' IIR state through the complete EQ chain.
        def flush(format: nil)
          return nil unless @runtime_format

          Enumerator.new do |yielder|
            @filters.each_with_index do |filter, index|
              DSP::Processor.flush(filter, format: format || @runtime_format).each do |tail|
                processed = @filters.drop(index + 1).reduce(tail) do |current, downstream|
                  DSP::Processor.process(downstream, current)
                end
                yielder << processed
              end
            end
          ensure
            @runtime_format = nil
          end
        end

        # @return [Float]
        def latency
          @filters.sum { |filter| DSP::Processor.duration(filter, :latency) }
        end

        # @return [Float]
        def lookahead
          @filters.sum { |filter| DSP::Processor.duration(filter, :lookahead) }
        end

        # @return [Float]
        def tail_duration
          @filters.sum { |filter| DSP::Processor.duration(filter, :tail_duration) }
        end
      end
    end
  end
end
