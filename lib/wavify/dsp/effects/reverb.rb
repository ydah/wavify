# frozen_string_literal: true

module Wavify
  module DSP
    module Effects
      # Lightweight Schroeder-style reverb effect.
      class Reverb < EffectBase
        COMB_TAPS_44K = [1116, 1188, 1277, 1356].freeze # :nodoc:
        ALLPASS_TAPS_44K = [556, 441].freeze # :nodoc:

        def initialize(room_size: 0.5, damping: 0.5, mix: 0.3)
          super()
          @room_size = validate_unit!(room_size, :room_size)
          @damping = validate_unit!(damping, :damping)
          @mix = validate_unit!(mix, :mix)
          reset
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

          comb_input = dry * @input_gain
          comb_sum = 0.0
          channel_state[:combs].each do |comb|
            comb_sum += process_comb(comb, comb_input)
          end

          wet = comb_sum / channel_state[:combs].length
          channel_state[:allpasses].each do |allpass|
            wet = process_allpass(allpass, wet)
          end

          (dry * (1.0 - @mix)) + (wet * @mix)
        end

        private

        def prepare_runtime_state(sample_rate:, channels:)
          scale = sample_rate.to_f / 44_100.0
          comb_feedback = 0.6 + (@room_size * 0.34)
          damping = @damping

          @input_gain = 0.35
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
            { combs: combs, allpasses: allpasses }
          end
        end

        def reset_runtime_state
          @channels_state = []
          @input_gain = nil
        end

        def process_comb(comb, input_sample)
          buffer = comb[:buffer]
          index = comb[:index]
          delayed = buffer[index]

          filter_store = (delayed * (1.0 - comb[:damping])) + (comb[:filter_store] * comb[:damping])
          comb[:filter_store] = filter_store
          buffer[index] = (input_sample + (filter_store * comb[:feedback])).clamp(-1.0, 1.0)
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
      end
    end
  end
end
