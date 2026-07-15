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
          processed = @filters.reduce(buffer) do |current, filter|
            filter.respond_to?(:apply) ? filter.apply(current) : filter.process(current)
          end
          @runtime_format = buffer.format
          processed
        end

        alias apply process

        # Resets stateful filters in the chain.
        #
        # @return [EQ] self
        def reset
          @filters.each { |filter| filter.reset if filter.respond_to?(:reset) }
          @runtime_format = nil
          self
        end

        # Drains the filters' IIR state through the complete EQ chain.
        def flush(format: nil)
          return nil unless @runtime_format

          runtime_format = @runtime_format
          frames = (tail_duration * runtime_format.sample_rate).ceil
          return nil if frames.zero?

          silence = Core::SampleBuffer.new(Array.new(frames * runtime_format.channels, 0.0), runtime_format)
          tail = process(silence)
          reset
          tail.convert(format || runtime_format)
        end

        # @return [Float]
        def latency
          @filters.sum { |filter| filter.respond_to?(:latency) ? filter.latency.to_f : 0.0 }
        end

        # @return [Float]
        def lookahead
          @filters.map { |filter| filter.respond_to?(:lookahead) ? filter.lookahead.to_f : 0.0 }.max || 0.0
        end

        # @return [Float]
        def tail_duration
          @filters.map { |filter| filter.respond_to?(:tail_duration) ? filter.tail_duration.to_f : 0.0 }.max || 0.0
        end
      end
    end
  end
end
