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

          @effects.reduce(buffer) { |current, effect| process_effect(effect, current) }
        end

        # Applies every effect using its offline entrypoint when available.
        def apply(buffer)
          raise InvalidParameterError, "buffer must be Core::SampleBuffer" unless buffer.is_a?(Core::SampleBuffer)

          @effects.reduce(buffer) do |current, effect|
            result = if effect.respond_to?(:apply)
                       effect.apply(current)
                     elsif effect.respond_to?(:process)
                       effect.process(current)
                     else
                       effect.call(current)
                     end
            result.is_a?(Wavify::Audio) ? result.buffer : result
          end
        end

        # Flushes effect tails through every downstream processor.
        def flush(format: nil)
          tails = []
          @effects.each_with_index do |effect, index|
            next unless effect.respond_to?(:flush)

            tail = effect.flush(format: format)
            next unless tail&.sample_frame_count&.positive?

            processed = @effects.drop(index + 1).reduce(tail) do |current, downstream|
              process_effect(downstream, current)
            end
            tails << processed
          end
          return nil if tails.empty?

          tails.reduce { |combined, tail| combined.concat(tail) }
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

        def process_effect(effect, buffer)
          result = if effect.respond_to?(:process)
                     effect.process(buffer)
                   elsif effect.respond_to?(:call)
                     effect.call(buffer)
                   else
                     effect.apply(buffer)
                   end
          result.is_a?(Wavify::Audio) ? result.buffer : result
        end

        def validate_effect!(effect)
          return effect if effect.respond_to?(:process) || effect.respond_to?(:call) || effect.respond_to?(:apply)

          raise InvalidParameterError, "chain effects must respond to :process, :call, or :apply"
        end
      end
    end
  end
end
