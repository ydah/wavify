# frozen_string_literal: true

module Wavify
  module Sequencer
    # Immutable sequencer track definition consumed by {Engine}.
    class Track
      # Chord suffix to semitone interval mapping.
      CHORD_INTERVALS = {
        "" => [0, 4, 7],
        "M" => [0, 4, 7],
        "MAJ" => [0, 4, 7],
        "MAJ7" => [0, 4, 7, 11],
        "7" => [0, 4, 7, 10],
        "M7" => [0, 3, 7, 10],
        "MIN" => [0, 3, 7],
        "MIN7" => [0, 3, 7, 10],
        "MIN9" => [0, 3, 7, 10, 14],
        "MINOR" => [0, 3, 7],
        "M7B5" => [0, 3, 6, 10],
        "M7-5" => [0, 3, 6, 10],
        "DIM" => [0, 3, 6],
        "DIM7" => [0, 3, 6, 9],
        "AUG" => [0, 4, 8],
        "SUS2" => [0, 2, 7],
        "SUS4" => [0, 5, 7],
        "MAJ9" => [0, 4, 7, 11, 14]
      }.merge(
        "m" => [0, 3, 7],
        "m7" => [0, 3, 7, 10],
        "m9" => [0, 3, 7, 10, 14],
        "maj7" => [0, 4, 7, 11],
        "maj9" => [0, 4, 7, 11, 14],
        "sus2" => [0, 2, 7],
        "sus4" => [0, 5, 7],
        "dim" => [0, 3, 6],
        "dim7" => [0, 3, 6, 9],
        "aug" => [0, 4, 8]
      ).freeze

      SCALE_INTERVALS = {
        major: [0, 2, 4, 5, 7, 9, 11],
        minor: [0, 2, 3, 5, 7, 8, 10],
        chromatic: (0..11).to_a,
        pentatonic_major: [0, 2, 4, 7, 9],
        pentatonic_minor: [0, 3, 5, 7, 10]
      }.freeze

      attr_reader :name, :pattern, :note_sequence, :chord_progression, :waveform, :gain_db, :pan_position,
                  :pattern_resolution, :note_resolution, :default_octave, :envelope, :effects, :key_root, :scale,
                  :chord_voicing

      def initialize(name, **options)
        @name = validate_name!(name)
        pattern_resolution = options.fetch(:pattern_resolution, 16)
        note_resolution = options.fetch(:note_resolution, 8)
        default_octave = options.fetch(:default_octave, 4)

        @pattern_resolution = validate_resolution!(pattern_resolution, :pattern_resolution)
        @note_resolution = validate_resolution!(note_resolution, :note_resolution)
        @default_octave = validate_default_octave!(default_octave)
        @waveform = options.fetch(:waveform, :sine).to_sym
        @gain_db = validate_numeric!(options.fetch(:gain_db, 0.0), :gain_db).to_f
        @pan_position = validate_pan!(options.fetch(:pan_position, 0.0))
        @envelope = validate_envelope!(options[:envelope])
        @effects = validate_effects!(options.fetch(:effects, []))
        @key_root = normalize_key_root(options[:key])
        @scale = normalize_scale(options[:scale])
        @chord_voicing = normalize_chord_voicing(options[:chord_voicing])

        @pattern = coerce_pattern(options[:pattern])
        @note_sequence = coerce_note_sequence(options[:note_sequence])
        @chord_progression = coerce_chord_progression(options[:chord_progression])
      end

      # Returns a copy with a new pattern.
      #
      # @param pattern [Pattern, String]
      # @return [Track]
      def with_pattern(pattern)
        copy(pattern: pattern)
      end

      # Returns a copy with a new note sequence.
      #
      # @param notes [NoteSequence, String]
      # @param default_octave [Integer]
      # @return [Track]
      def with_notes(notes, default_octave: @default_octave)
        copy(note_sequence: notes, default_octave: default_octave)
      end

      # Returns a copy with a new chord progression.
      #
      # @param chords [String, Array<String>]
      # @param default_octave [Integer]
      # @return [Track]
      def with_chords(chords, default_octave: @default_octave)
        copy(chord_progression: chords, default_octave: default_octave)
      end

      # Returns a copy with scale quantization settings.
      #
      # @param key [Symbol, String, nil]
      # @param scale [Symbol, String, nil]
      # @return [Track]
      def with_key(key, scale: @scale)
        copy(key: key, scale: scale)
      end

      # Returns a copy with chord voicing settings.
      #
      # @param voicing [Symbol, String, nil]
      # @return [Track]
      def with_chord_voicing(voicing)
        copy(chord_voicing: voicing)
      end

      # Returns a copy with a different oscillator waveform.
      #
      # @param waveform [Symbol, String]
      # @return [Track]
      def with_synth(waveform)
        copy(waveform: waveform)
      end

      # Returns a copy with updated gain in dB.
      #
      # @param db [Numeric]
      # @return [Track]
      def with_gain(db)
        copy(gain_db: db)
      end

      # Returns a copy with updated pan position.
      #
      # @param position [Numeric]
      # @return [Track]
      def with_pan(position)
        copy(pan_position: position)
      end

      # Returns a copy with an envelope object.
      #
      # @param envelope [Wavify::DSP::Envelope, nil]
      # @return [Track]
      def with_envelope(envelope)
        copy(envelope: envelope)
      end

      # Returns a copy with effect processors.
      #
      # @param effects [Array<Object>]
      # @return [Track]
      def with_effects(effects)
        copy(effects: effects)
      end

      def event_sources?
        pattern? || notes? || chords?
      end

      def pattern?
        !@pattern.nil?
      end

      def notes?
        !@note_sequence.nil?
      end

      def chords?
        !@chord_progression.nil? && !@chord_progression.empty?
      end

      def effects?
        !@effects.empty?
      end

      # Copy constructor used by immutable builder helpers.
      #
      # @return [Track]
      def copy(**overrides)
        self.class.new(
          overrides.fetch(:name, @name),
          pattern: overrides.fetch(:pattern, @pattern),
          note_sequence: overrides.fetch(:note_sequence, @note_sequence),
          chord_progression: overrides.fetch(:chord_progression, @chord_progression),
          waveform: overrides.fetch(:waveform, @waveform),
          gain_db: overrides.fetch(:gain_db, @gain_db),
          pan_position: overrides.fetch(:pan_position, @pan_position),
          pattern_resolution: overrides.fetch(:pattern_resolution, @pattern_resolution),
          note_resolution: overrides.fetch(:note_resolution, @note_resolution),
          default_octave: overrides.fetch(:default_octave, @default_octave),
          envelope: overrides.fetch(:envelope, @envelope),
          effects: overrides.fetch(:effects, @effects),
          key: overrides.fetch(:key, @key_root),
          scale: overrides.fetch(:scale, @scale),
          chord_voicing: overrides.fetch(:chord_voicing, @chord_voicing)
        )
      end

      # Parses chord notation using this track's default octave.
      #
      # @param chords [String, Array<String>]
      # @return [Array<Hash>]
      def parse_chords(chords)
        self.class.parse_chords(chords, default_octave: @default_octave)
      end

      def self.parse_chords(chords, default_octave: 4)
        tokens = case chords
                 when String
                   chords.split(/\s+/)
                 when Array
                   chords.map(&:to_s)
                 else
                   raise InvalidNoteError, "chords must be String or Array"
                 end.reject(&:empty?)

        raise InvalidNoteError, "chords must not be empty" if tokens.empty?

        tokens.map { |token| parse_chord_token(token, default_octave: default_octave) }
      end

      def self.parse_chord_token(token, default_octave:)
        chord_token, inline_voicing = token.to_s.split("@", 2)
        match = chord_token.match(/\A([A-Ga-g])([#b]?)(.*)\z/)
        raise InvalidNoteError, "invalid chord token: #{token.inspect}" unless match

        root_name = "#{match[1].upcase}#{match[2]}"
        suffix, bass_name = match[3].to_s.split("/", 2)
        suffix_key = normalize_chord_suffix(suffix)
        intervals = CHORD_INTERVALS[suffix_key] || CHORD_INTERVALS[suffix]
        raise InvalidNoteError, "unsupported chord quality: #{suffix.inspect}" unless intervals

        root_midi = NoteSequence.new("#{root_name}#{default_octave}", default_octave: default_octave).midi_notes.first
        midi_notes = intervals.map { |interval| root_midi + interval }
        midi_notes = apply_chord_inversion(midi_notes, bass_name, root_midi, default_octave) if bass_name
        midi_notes = apply_chord_voicing(midi_notes, inline_voicing) if inline_voicing
        {
          token: token,
          root_midi: root_midi,
          midi_notes: midi_notes
        }
      end

      def self.apply_chord_inversion(midi_notes, bass_name, root_midi, default_octave)
        bass = NoteSequence.new("#{bass_name}#{default_octave}", default_octave: default_octave).midi_notes.first
        bass -= 12 while bass > root_midi
        remaining = midi_notes.reject { |midi| midi % 12 == bass % 12 }
        [bass, *remaining].sort
      end

      def self.apply_chord_voicing(midi_notes, voicing)
        case normalize_chord_voicing(voicing)
        when nil, :root
          midi_notes
        when :open
          midi_notes.each_with_index.map { |midi, index| index.odd? ? midi + 12 : midi }.sort
        when :drop2
          return midi_notes if midi_notes.length < 3

          ordered = midi_notes.sort
          dropped = ordered.delete_at(-2) - 12
          [dropped, *ordered].sort
        else
          midi_notes
        end
      end

      def self.normalize_chord_suffix(suffix)
        value = suffix.to_s
        return "" if value.empty?

        if value.start_with?("m") && !value.start_with?("maj")
          "m#{value[1..]}"
        else
          value.downcase
        end
      end

      private_class_method :normalize_chord_suffix

      def quantize_midi_note(midi_note)
        return midi_note unless @key_root && @scale

        self.class.quantize_midi_note(midi_note, key: @key_root, scale: @scale)
      end

      def self.quantize_midi_note(midi_note, key:, scale:)
        key_pitch = NoteSequence::NOTE_OFFSETS.fetch(key.to_s.upcase)
        intervals = SCALE_INTERVALS.fetch(scale.to_sym)
        octave = midi_note / 12
        candidates = ((octave - 1)..(octave + 1)).flat_map do |candidate_octave|
          base = (candidate_octave * 12) + key_pitch
          intervals.map { |interval| base + interval }
        end.select { |candidate| candidate.between?(0, 127) }
        candidates.min_by { |candidate| [(candidate - midi_note).abs, candidate] } || midi_note
      end

      private

      def validate_name!(name)
        value = name.to_sym
        raise SequencerError, "track name must not be empty" if value.to_s.empty?

        value
      rescue NoMethodError
        raise SequencerError, "track name must be Symbol/String: #{name.inspect}"
      end

      def validate_resolution!(value, name)
        raise SequencerError, "#{name} must be a positive Integer" unless value.is_a?(Integer) && value.positive?

        value
      end

      def validate_default_octave!(value)
        raise SequencerError, "default_octave must be an Integer" unless value.is_a?(Integer)

        value
      end

      def validate_numeric!(value, name)
        raise SequencerError, "#{name} must be Numeric" unless value.is_a?(Numeric)

        value
      end

      def validate_pan!(value)
        raise SequencerError, "pan_position must be Numeric in -1.0..1.0" unless value.is_a?(Numeric) && value.between?(-1.0, 1.0)

        value.to_f
      end

      def validate_envelope!(value)
        return nil if value.nil?
        raise SequencerError, "envelope must be a Wavify::DSP::Envelope" unless value.is_a?(Wavify::DSP::Envelope)

        value
      end

      def validate_effects!(value)
        effects = Array(value)
        unless effects.all? { |effect| effect.respond_to?(:process) || effect.respond_to?(:apply) || effect.respond_to?(:call) }
          raise SequencerError, "effects must respond to :process, :apply, or :call"
        end

        effects.freeze
      end

      def normalize_key_root(value)
        return nil if value.nil?

        key = value.to_s.upcase
        raise SequencerError, "key must be a note name" unless NoteSequence::NOTE_OFFSETS.key?(key)

        key
      end

      def normalize_scale(value)
        return nil if value.nil?

        scale = value.to_sym
        raise SequencerError, "unsupported scale: #{value.inspect}" unless SCALE_INTERVALS.key?(scale)

        scale
      rescue NoMethodError
        raise SequencerError, "scale must be Symbol/String"
      end

      def normalize_chord_voicing(value)
        self.class.send(:normalize_chord_voicing, value)
      end

      def self.normalize_chord_voicing(value)
        return nil if value.nil?

        voicing = value.to_sym
        return voicing if %i[root open drop2].include?(voicing)

        raise SequencerError, "unsupported chord voicing: #{value.inspect}"
      rescue NoMethodError
        raise SequencerError, "chord_voicing must be Symbol/String"
      end

      def coerce_pattern(pattern)
        return nil if pattern.nil?
        return pattern if pattern.is_a?(Pattern)

        Pattern.new(pattern, resolution: @pattern_resolution)
      end

      def coerce_note_sequence(note_sequence)
        return nil if note_sequence.nil?
        return note_sequence if note_sequence.is_a?(NoteSequence)

        NoteSequence.new(note_sequence, default_octave: @default_octave)
      end

      def coerce_chord_progression(chord_progression)
        return nil if chord_progression.nil?
        if chord_progression.is_a?(Array) && chord_progression.all? { |item| item.is_a?(Hash) && item[:midi_notes] }
          return chord_progression
        end

        self.class.parse_chords(chord_progression, default_octave: @default_octave)
                   .map { |chord| apply_track_chord_options(chord) }
      end

      def apply_track_chord_options(chord)
        midi_notes = chord.fetch(:midi_notes).map { |midi| quantize_midi_note(midi) }
        midi_notes = self.class.apply_chord_voicing(midi_notes, @chord_voicing) if @chord_voicing
        chord.merge(midi_notes: midi_notes)
      end
    end
  end
end
