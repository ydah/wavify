# frozen_string_literal: true

module Wavify
  module Sequencer
    # Step-pattern parser (`x`, `X`, `-`, `.`) for trigger sequencing.
    class Pattern
      include Enumerable

      # Parsed pattern step value object.
      Step = Struct.new(:index, :trigger, :accent, :symbol, :velocity, keyword_init: true) do
        def rest?
          !trigger
        end

        def trigger?
          trigger
        end

        def accent?
          accent
        end
      end

      attr_reader :resolution, :steps, :notation

      def initialize(notation, resolution: 16)
        @notation = notation
        @resolution = validate_resolution!(resolution)
        @steps = parse_steps(notation).freeze
      end

      # Enumerates parsed steps.
      #
      # @yield [step]
      # @yieldparam step [Step]
      # @return [Enumerator]
      def each(&)
        return enum_for(:each) unless block_given?

        @steps.each(&)
      end

      # Returns a step at the given index.
      #
      # @param index [Integer]
      # @return [Step, nil]
      def [](index)
        @steps[index]
      end

      # @return [Integer] number of steps
      def length
        @steps.length
      end

      alias size length

      # @return [Array<Integer>] indices for trigger steps
      def trigger_indices
        @steps.select(&:trigger?).map(&:index)
      end

      # @return [Array<Integer>] indices for accented trigger steps
      def accented_indices
        @steps.select(&:accent?).map(&:index)
      end

      # @return [Array<Step>] copy of parsed steps
      def to_a
        @steps.dup
      end

      private

      def validate_resolution!(value)
        raise InvalidPatternError, "resolution must be a positive Integer" unless value.is_a?(Integer) && value.positive?

        value
      end

      def parse_steps(notation)
        raise InvalidPatternError, "pattern notation must be String" unless notation.is_a?(String)

        chars = notation.each_char.reject { |char| char =~ /\s/ || char == "|" }
        raise InvalidPatternError, "pattern notation must not be empty" if chars.empty?

        chars.each_with_index.map do |char, index|
          case char
          when "x"
            Step.new(index: index, trigger: true, accent: false, symbol: char, velocity: 0.8)
          when "X"
            Step.new(index: index, trigger: true, accent: true, symbol: char, velocity: 1.0)
          when "-", "."
            Step.new(index: index, trigger: false, accent: false, symbol: char, velocity: 0.0)
          else
            raise InvalidPatternError, "invalid pattern symbol #{char.inspect} at step #{index}"
          end
        end
      end
    end
  end
end
