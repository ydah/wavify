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

          original_format = buffer.format
          float_format = original_format.with(sample_format: :float, bit_depth: 32)
          processed = @effects.reduce(buffer.convert(float_format)) { |current, effect| process_effect(effect, current) }
          processed.convert(original_format)
        end

        # Applies every effect using its offline entrypoint when available.
        def apply(buffer)
          raise InvalidParameterError, "buffer must be Core::SampleBuffer" unless buffer.is_a?(Core::SampleBuffer)

          DSP::Processor.render(self, buffer)
        end

        # Flushes effect tails through every downstream processor.
        def flush(format: nil)
          Enumerator.new do |yielder|
            @effects.each_with_index do |effect, index|
              DSP::Processor.flush(effect, format: format).each do |tail|
                next unless tail.sample_frame_count.positive?

                processed = @effects.drop(index + 1).reduce(tail) do |current, downstream|
                  process_effect(downstream, current)
                end
                yielder << processed
              end
            end
          end
        end

        # @return [EffectChain] self
        def reset
          @effects.each { |effect| effect.reset if effect.respond_to?(:reset) }
          self
        end

        # Builds a chain whose processors do not share runtime state.
        def build_runtime
          runtime_effects = @effects.map { |effect| DSP::Processor.build_runtime(effect) }
          runtime = dup
          runtime.instance_variable_set(:@effects, runtime_effects.freeze)
          runtime.reset
        end

        # @return [Float]
        def latency
          @effects.sum { |effect| DSP::Processor.duration(effect, :latency) }
        end

        # @return [Float]
        def lookahead
          @effects.sum { |effect| DSP::Processor.duration(effect, :lookahead) }
        end

        # @return [Float]
        def tail_duration
          @effects.sum { |effect| DSP::Processor.duration(effect, :tail_duration) }
        end

        private

        def process_effect(effect, buffer)
          DSP::Processor.process(effect, buffer)
        end

        def validate_effect!(effect)
          return effect if effect.respond_to?(:process) || effect.respond_to?(:call) || effect.respond_to?(:apply)

          raise InvalidParameterError, "chain effects must respond to :process, :call, or :apply"
        end
      end
    end
  end
end
