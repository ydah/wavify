# frozen_string_literal: true

module Wavify
  module Sequencer
    # Note sequence parser for note/rest/MIDI token notation.
    class NoteSequence
      include Enumerable

      # Note-name to semitone offset lookup table.
      NOTE_OFFSETS = {
        "C" => 0,
        "C#" => 1,
        "DB" => 1,
        "D" => 2,
        "D#" => 3,
        "EB" => 3,
        "E" => 4,
        "F" => 5,
        "F#" => 6,
        "GB" => 6,
        "G" => 7,
        "G#" => 8,
        "AB" => 8,
        "A" => 9,
        "A#" => 10,
        "BB" => 10,
        "B" => 11
      }.freeze

      # Parsed note event (`midi_note` is `nil` for rests).
      Event = Struct.new(:index, :token, :midi_note, keyword_init: true) do
        def rest?
          midi_note.nil?
        end
      end

      attr_reader :default_octave, :events, :notation

      def initialize(notation, default_octave: 4)
        @notation = notation
        @default_octave = validate_default_octave!(default_octave)
        @events = parse_events(notation).freeze
      end

      # Enumerates parsed events.
      #
      # @yield [event]
      # @yieldparam event [Event]
      # @return [Enumerator]
      def each(&)
        return enum_for(:each) unless block_given?

        @events.each(&)
      end

      # Returns an event at the given index.
      #
      # @param index [Integer]
      # @return [Event, nil]
      def [](index)
        @events[index]
      end

      # @return [Integer] number of parsed events
      def length
        @events.length
      end

      alias size length

      # @return [Array<Integer, nil>] MIDI notes preserving rests as nil
      def midi_notes
        @events.map(&:midi_note)
      end

      # @return [Array<Event>] events excluding rests
      def note_events
        @events.reject(&:rest?)
      end

      private

      def validate_default_octave!(value)
        raise InvalidNoteError, "default_octave must be an Integer" unless value.is_a?(Integer)

        value
      end

      def parse_events(notation)
        raise InvalidNoteError, "note sequence notation must be String" unless notation.is_a?(String)

        tokens = notation.split(/\s+/).reject(&:empty?)
        raise InvalidNoteError, "note sequence notation must not be empty" if tokens.empty?

        tokens.each_with_index.map do |token, index|
          Event.new(index: index, token: token, midi_note: parse_token(token))
        end
      end

      def parse_token(token)
        return nil if token == "."

        return parse_midi_number(token) if token.match?(/\A-?\d+\z/)

        parse_note_name(token)
      end

      def parse_midi_number(token)
        midi = token.to_i
        raise InvalidNoteError, "MIDI note out of range (0..127): #{token}" unless midi.between?(0, 127)

        midi
      end

      def parse_note_name(token)
        match = token.match(/\A([A-Ga-g])([#b]?)(-?\d+)?\z/)
        raise InvalidNoteError, "invalid note token: #{token.inspect}" unless match

        note_name = "#{match[1].upcase}#{match[2]}".upcase
        octave = match[3] ? match[3].to_i : @default_octave

        semitone = NOTE_OFFSETS[note_name]
        raise InvalidNoteError, "unsupported note token: #{token.inspect}" unless semitone

        midi = ((octave + 1) * 12) + semitone
        raise InvalidNoteError, "note out of MIDI range: #{token.inspect}" unless midi.between?(0, 127)

        midi
      end
    end
  end
end
