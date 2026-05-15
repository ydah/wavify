# frozen_string_literal: true

module Wavify
  module DSP
    module Effects
      # Processor that applies a fixed list of effects in sequence.
      class EffectChain
        attr_reader :effects

        # @param effects [Array<#process,#call,#apply>]
        def initialize(effects)
          raise InvalidParameterError, "effects must be an Array" unless effects.is_a?(Array)

          @effects = effects.map { |effect| validate_effect!(effect) }.freeze
        end

        # @param buffer [Wavify::Core::SampleBuffer]
        # @return [Wavify::Core::SampleBuffer]
        def process(buffer)
          raise InvalidParameterError, "buffer must be Core::SampleBuffer" unless buffer.is_a?(Core::SampleBuffer)

          @effects.reduce(buffer) do |current, effect|
            if effect.respond_to?(:process)
              effect.process(current)
            elsif effect.respond_to?(:apply)
              applied = effect.apply(current)
              applied.is_a?(Wavify::Audio) ? applied.buffer : applied
            else
              effect.call(current)
            end
          end
        end

        # @return [EffectChain] self
        def reset
          @effects.each { |effect| effect.reset if effect.respond_to?(:reset) }
          self
        end

        # @return [Float]
        def latency
          @effects.sum { |effect| effect.respond_to?(:latency) ? effect.latency.to_f : 0.0 }
        end

        # @return [Float]
        def lookahead
          @effects.map { |effect| effect.respond_to?(:lookahead) ? effect.lookahead.to_f : 0.0 }.max || 0.0
        end

        # @return [Float]
        def tail_duration
          @effects.map { |effect| effect.respond_to?(:tail_duration) ? effect.tail_duration.to_f : 0.0 }.max || 0.0
        end

        private

        def validate_effect!(effect)
          return effect if effect.respond_to?(:process) || effect.respond_to?(:call) || effect.respond_to?(:apply)

          raise InvalidParameterError, "chain effects must respond to :process, :call, or :apply"
        end
      end
    end
  end
end
