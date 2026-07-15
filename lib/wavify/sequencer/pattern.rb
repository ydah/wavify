# frozen_string_literal: true

module Wavify
  module Sequencer
    # Step-pattern parser (`x`, `X`, `x0.7`, `x?50`, `x:3`, `-`, `.`) for trigger sequencing.
    class Pattern
      include Enumerable

      # Highest supported step-grid resolution per bar.
      MAX_RESOLUTION = 4_096
      # Highest supported retrigger count for one pattern step.
      MAX_RATCHET = 64

      # Parsed pattern step value object.
      Step = Struct.new(:index, :trigger, :accent, :symbol, :velocity, :probability, :ratchet, keyword_init: true) do
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
        raise InvalidPatternError, "pattern notation must be String" unless notation.is_a?(String)

        @notation = notation.dup.freeze
        @resolution = validate_resolution!(resolution)
        @steps = parse_steps(@notation).freeze
        if @steps.length > @resolution
          raise InvalidPatternError, "pattern has #{@steps.length} steps but resolution is #{@resolution}"
        end
        freeze
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
        unless value.is_a?(Integer) && value.between?(1, MAX_RESOLUTION)
          raise InvalidPatternError, "resolution must be an Integer between 1 and #{MAX_RESOLUTION}"
        end

        value
      end

      def parse_steps(notation)
        raise InvalidPatternError, "pattern notation must be String" unless notation.is_a?(String)

        chars = notation.each_char.reject { |char| char =~ /\s/ || char == "|" }.join
        raise InvalidPatternError, "pattern notation must not be empty" if chars.empty?

        steps = []
        cursor = 0
        while cursor < chars.length
          char = chars[cursor]
          index = steps.length

          case char
          when "x", "X"
            cursor += 1
            velocity_text, cursor = scan_velocity_suffix(chars, cursor)
            probability, ratchet, cursor = scan_trigger_modifiers(chars, cursor, index)
            default_velocity = char == "X" ? 1.0 : 0.8
            velocity = velocity_text ? parse_velocity!(velocity_text, index) : default_velocity
            steps << Step.new(
              index: index,
              trigger: true,
              accent: char == "X",
              symbol: char,
              velocity: velocity,
              probability: probability,
              ratchet: ratchet
            ).freeze
          when "-", "."
            steps << Step.new(
              index: index, trigger: false, accent: false, symbol: char, velocity: 0.0, probability: 0.0, ratchet: 1
            ).freeze
            cursor += 1
          else
            raise InvalidPatternError, "invalid pattern symbol #{char.inspect} at step #{index}"
          end
        end

        steps
      end

      def scan_velocity_suffix(chars, cursor)
        return [nil, cursor] unless chars[cursor]&.match?(/\d/)

        start = cursor
        cursor += 1
        cursor += 1 while cursor < chars.length && chars[cursor].match?(/\d/)
        if chars[cursor] == "."
          cursor += 1
          cursor += 1 while cursor < chars.length && chars[cursor].match?(/\d/)
        end
        [chars[start...cursor], cursor]
      end

      def scan_trigger_modifiers(chars, cursor, index)
        probability = 1.0
        ratchet = 1
        seen = {}

        while cursor < chars.length && ["?", ":"].include?(chars[cursor])
          modifier = chars[cursor]
          raise InvalidPatternError, "duplicate modifier #{modifier.inspect} at step #{index}" if seen[modifier]

          seen[modifier] = true
          case modifier
          when "?"
            text, cursor = scan_numeric_modifier(chars, cursor + 1, "probability", index)
            probability = parse_probability!(text, index)
          when ":"
            text, cursor = scan_numeric_modifier(chars, cursor + 1, "ratchet", index)
            ratchet = parse_ratchet!(text, index)
          end
        end

        [probability, ratchet, cursor]
      end

      def scan_numeric_modifier(chars, cursor, name, index)
        start = cursor
        cursor += 1 while cursor < chars.length && chars[cursor].match?(/\d/)
        if chars[cursor] == "."
          cursor += 1
          cursor += 1 while cursor < chars.length && chars[cursor].match?(/\d/)
        end
        raise InvalidPatternError, "missing #{name} value at step #{index}" if start == cursor

        [chars[start...cursor], cursor]
      end

      def parse_velocity!(text, index)
        velocity = Float(text)
        return velocity if velocity.between?(0.0, 1.0)

        raise InvalidPatternError, "velocity must be between 0.0 and 1.0 at step #{index}"
      rescue ArgumentError
        raise InvalidPatternError, "invalid velocity #{text.inspect} at step #{index}"
      end

      def parse_probability!(text, index)
        probability = Float(text) / 100.0
        return probability if probability.between?(0.0, 1.0)

        raise InvalidPatternError, "probability must be between 0 and 100 at step #{index}"
      rescue ArgumentError
        raise InvalidPatternError, "invalid probability #{text.inspect} at step #{index}"
      end

      def parse_ratchet!(text, index)
        ratchet = Integer(text)
        return ratchet if ratchet.between?(1, MAX_RATCHET)

        raise InvalidPatternError, "ratchet must be between 1 and #{MAX_RATCHET} at step #{index}"
      rescue ArgumentError
        raise InvalidPatternError, "invalid ratchet #{text.inspect} at step #{index}"
      end
    end
  end
end
