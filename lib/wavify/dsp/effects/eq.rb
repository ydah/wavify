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
          @filters.reduce(buffer) do |current, filter|
            filter.respond_to?(:apply) ? filter.apply(current) : filter.process(current)
          end
        end

        alias apply process

        # Resets stateful filters in the chain.
        #
        # @return [EQ] self
        def reset
          @filters.each { |filter| filter.reset if filter.respond_to?(:reset) }
          self
        end

        # @return [Float]
        def latency
          @filters.sum { |filter| filter.respond_to?(:latency) ? filter.latency.to_f : 0.0 }
        end

        # @return [Float]
        def lookahead
          @filters.sum { |filter| filter.respond_to?(:lookahead) ? filter.lookahead.to_f : 0.0 }
        end

        # @return [Float]
        def tail_duration
          @filters.map { |filter| filter.respond_to?(:tail_duration) ? filter.tail_duration.to_f : 0.0 }.max || 0.0
        end
      end
    end
  end
end
