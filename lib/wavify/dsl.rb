# frozen_string_literal: true

require "fileutils"
require "json"

module Wavify
  # Declarative music-building DSL that compiles to sequencer tracks and audio.
  module DSL
    # Immutable compiled song definition returned by {DSL.build_definition}.
    class SongDefinition
      # Arrangement section metadata (`name`, `bars`, active `tracks`).
      Section = Struct.new(:name, :bars, :tracks, :repeat, keyword_init: true)

      attr_reader :format, :tempo, :beats_per_bar, :swing, :tracks, :sections, :default_bars

      def initialize(format:, tempo:, beats_per_bar:, swing:, default_bars:, tracks:, sections:)
        @format = format
        @tempo = tempo
        @beats_per_bar = beats_per_bar
        @swing = swing
        @default_bars = default_bars
        @tracks = tracks.freeze
        @sections = sections.freeze
      end

      def arrangement?
        !@sections.empty?
      end

      # Returns a sequencer engine configured from the song definition.
      #
      # @return [Wavify::Sequencer::Engine]
      def engine
        Wavify::Sequencer::Engine.new(
          tempo: @tempo,
          format: @format,
          beats_per_bar: @beats_per_bar,
          swing: @swing
        )
      end

      # Returns sequencer tracks converted from DSL track definitions.
      #
      # @return [Array<Wavify::Sequencer::Track>]
      def sequencer_tracks
        @tracks.map(&:to_sequencer_track)
      end

      # Returns arrangement sections as hashes accepted by the sequencer engine.
      #
      # @return [Array<Hash>]
      def arrangement
        @sections.flat_map do |section|
          Array.new(section.repeat || 1) do |repeat_index|
            {
              name: repeated_section_name(section.name, repeat_index),
              bars: section.bars,
              tracks: section.tracks
            }
          end
        end
      end

      # Planned song duration derived from arrangement/default bars.
      #
      # @param default_bars [Integer]
      # @return [Wavify::Core::Duration]
      def duration(default_bars: @default_bars)
        Core::Duration.new(total_bars(default_bars: default_bars) * engine.bar_duration_seconds)
      end

      alias length duration

      # Builds a sequencer event timeline without rendering audio.
      #
      # @param default_bars [Integer]
      # @return [Array<Hash>]
      def timeline(default_bars: @default_bars)
        engine.build_timeline(
          tracks: sequencer_tracks,
          arrangement: arrangement? ? arrangement : nil,
          default_bars: default_bars
        )
      end

      # Serializes the sequencer timeline to JSON for visualization tooling.
      #
      # @param default_bars [Integer]
      # @return [String]
      def timeline_json(default_bars: @default_bars)
        JSON.generate(timeline(default_bars: default_bars))
      end

      # Renders the song definition to an {Wavify::Audio} instance.
      #
      # @param default_bars [Integer]
      # @param stems [Boolean] return track-name keyed stems instead of a mix
      # @return [Wavify::Audio]
      def render(default_bars: @default_bars, stems: false)
        return render_stems(default_bars: default_bars) if stems

        sequencer_audio = engine.render(
          tracks: sequencer_tracks,
          arrangement: arrangement? ? arrangement : nil,
          default_bars: default_bars
        )
        sample_audio = render_sample_tracks(default_bars: default_bars)

        return sequencer_audio unless sample_audio
        return sample_audio if sequencer_audio.sample_frame_count.zero?

        Wavify::Audio.mix(sequencer_audio, sample_audio)
      end

      # Renders and writes the song to disk.
      #
      # @param path [String]
      # @param default_bars [Integer]
      # @return [Wavify::Audio]
      def write(path, default_bars: @default_bars)
        render(default_bars: default_bars).write(path)
      end

      # Renders each track and writes stems as WAV files under a directory.
      #
      # @param directory [String]
      # @param default_bars [Integer]
      # @param overwrite [Boolean]
      # @return [Hash<Symbol, String>]
      def write_stems(directory, default_bars: @default_bars, overwrite: true)
        raise Wavify::InvalidParameterError, "directory must be a String" unless directory.is_a?(String)

        FileUtils.mkdir_p(directory)
        render(default_bars: default_bars, stems: true).each_with_object({}) do |(track_name, audio), paths|
          path = File.join(directory, "#{track_name}.wav")
          audio.write(path, overwrite: overwrite)
          paths[track_name] = path
        end
      end

      private

      def render_stems(default_bars:)
        @tracks.each_with_object({}) do |track, stems|
          audio = render_track_stem(track, default_bars: default_bars)
          stems[track.name] = audio
        end
      end

      def render_track_stem(track, default_bars:)
        sequencer_audio = render_sequencer_track_stem(track, default_bars: default_bars)
        sample_audio = render_sample_track(track, default_bars: default_bars)

        if sample_audio && sequencer_audio.sample_frame_count.positive?
          Wavify::Audio.mix(sequencer_audio, sample_audio)
        else
          sample_audio || sequencer_audio
        end
      end

      def render_sequencer_track_stem(track, default_bars:)
        arrangement_for_stem = arrangement? ? arrangement_for_track(track.name) : nil
        engine.render(
          tracks: [track.to_sequencer_track],
          arrangement: arrangement_for_stem,
          default_bars: default_bars
        )
      end

      def render_sample_tracks(default_bars:)
        rendered_tracks = @tracks.filter_map do |track|
          render_sample_track(track, default_bars: default_bars)
        end
        return nil if rendered_tracks.empty?

        Wavify::Audio.mix(*rendered_tracks)
      end

      def render_sample_track(track, default_bars:)
        patterns = track.sample_pattern_map
        return nil if patterns.empty?

        sections = active_sections_for(track.name, default_bars: default_bars)
        return nil if sections.empty?

        work_format = track_render_work_format
        sample_cache = {}
        events = []

        sections.each do |section|
          patterns.each do |sample_key, pattern|
            sample_audio = sample_cache[sample_key] ||= load_sample_audio(track, sample_key, work_format)
            step_duration = engine.step_duration_seconds(pattern.length)

            (0...section.fetch(:bars)).each do |bar_offset|
              absolute_bar = section.fetch(:start_bar) + bar_offset
              bar_base_time = absolute_bar * engine.bar_duration_seconds

              pattern.each do |step|
                next unless step.trigger?

                events << {
                  sample_key: sample_key,
                  start_time: bar_base_time + (step.index * step_duration),
                  velocity: step.velocity,
                  sample_audio: sample_audio
                }
              end
            end
          end
        end

        return nil if events.empty?

        total_end_time = events.map { |event| event[:start_time] + event.fetch(:sample_audio).duration.total_seconds }.max || 0.0
        base_audio = Wavify::Audio.silence(total_end_time, format: work_format)
        mixed = base_audio.buffer.samples.dup

        events.each do |event|
          overlay_sample_event!(mixed, event, work_format)
        end

        mixed.map! { |sample| sample.clamp(-1.0, 1.0) }
        rendered = Wavify::Audio.new(Wavify::Core::SampleBuffer.new(mixed, work_format))
        rendered = rendered.gain(track.gain_db) if track.gain_db != 0.0
        rendered = rendered.pan(track.pan_position) if track.pan_position != 0.0
        rendered = track.effect_processors.reduce(rendered) { |audio, effect| audio.apply(effect) }
        rendered.convert(@format)
      end

      def active_sections_for(track_name, default_bars:)
        if arrangement?
          cursor_bar = 0
          arrangement.each_with_object([]) do |section, result|
            result << { bars: section.fetch(:bars), start_bar: cursor_bar } if section.fetch(:tracks).include?(track_name)
            cursor_bar += section.fetch(:bars)
          end
        else
          [{ bars: default_bars, start_bar: 0 }]
        end
      end

      def track_render_work_format
        base = @format.channels == 2 ? @format : @format.with(channels: 2)
        base.with(sample_format: :float, bit_depth: 32)
      end

      def load_sample_audio(track, sample_key, work_format)
        path = track.samples[sample_key]
        raise Wavify::SequencerError, "missing sample mapping for pattern #{sample_key.inspect} on track #{track.name}" unless path

        apply_sample_options(
          Wavify::Audio.read(path),
          track.sample_options.fetch(sample_key, {}),
          work_format
        )
      rescue Wavify::Error => e
        raise Wavify::SequencerError, "failed to load sample #{path.inspect} for track #{track.name}: #{e.message}"
      end

      def apply_sample_options(audio, options, work_format)
        processed = audio
        processed = slice_sample_option(processed, options)
        processed = trim_sample_option(processed, options)
        processed = processed.reverse if options[:reverse]
        processed = processed.convert(work_format)
        processed = processed.gain(options[:gain]) if options.key?(:gain)
        processed = processed.pan(options[:pan]) if options.key?(:pan)
        processed.convert(work_format)
      end

      def slice_sample_option(audio, options)
        return audio.crop(start: options.fetch(:from, 0.0), duration: options[:duration]) if options.key?(:duration)
        return audio.slice(from: options.fetch(:from, 0.0), to: options[:to]) if options.key?(:to)

        audio
      end

      def trim_sample_option(audio, options)
        return audio unless options.key?(:trim)
        return audio if options[:trim] == false

        threshold = options[:trim] == true ? 0.01 : options[:trim]
        audio.trim(threshold: threshold)
      end

      def overlay_sample_event!(mixed, event, work_format)
        sample_audio = event.fetch(:sample_audio)
        velocity = event.fetch(:velocity).to_f
        start_frame = (event.fetch(:start_time) * work_format.sample_rate).round
        start_index = start_frame * work_format.channels

        sample_audio.buffer.samples.each_with_index do |sample, index|
          target_index = start_index + index
          break if target_index >= mixed.length

          mixed[target_index] += sample * velocity
        end
      end

      def arrangement_for_track(track_name)
        arrangement.filter_map do |section|
          next unless section.fetch(:tracks).include?(track_name)

          section.merge(tracks: [track_name])
        end
      end

      def total_bars(default_bars:)
        return default_bars unless arrangement?

        arrangement.sum { |section| section.fetch(:bars) }
      end

      def repeated_section_name(name, repeat_index)
        return name if repeat_index.zero?

        :"#{name}_#{repeat_index + 1}"
      end
    end

    # :nodoc: all
    # @api private
    class TrackDefinition
      # Internal mapping from DSL effect names to effect class constants.
      EFFECT_CLASS_NAMES = {
        delay: "Delay",
        reverb: "Reverb",
        chorus: "Chorus",
        distortion: "Distortion",
        compressor: "Compressor"
      }.freeze

      # Internal mutable track state compiled from DSL blocks.
      #
      # Readers are used by {SongDefinition} rendering and sequencer conversion.
      attr_reader :name, :waveform, :gain_db, :pan_position, :pattern_resolution, :note_resolution,
                  :default_octave, :envelope, :notes_notation, :chords_notation, :effects, :samples,
                  :sample_options, :named_patterns, :synth_options

      def initialize(name)
        @name = name.to_sym
        @waveform = :sine
        @gain_db = 0.0
        @pan_position = 0.0
        @pattern_resolution = 16
        @note_resolution = 8
        @default_octave = 4
        @envelope = nil
        @notes_notation = nil
        @chords_notation = nil
        @effects = []
        @samples = {}
        @sample_options = {}
        @named_patterns = {}
        @primary_pattern = nil
        @synth_options = {}
      end

      # Returns the primary pattern notation for sequencer rendering.
      def primary_pattern
        @primary_pattern || @named_patterns.values.first
      end

      # Registers a primary or named rhythm pattern.
      def pattern!(name_or_notation, notation = nil, resolution: nil)
        if notation.nil?
          @primary_pattern = name_or_notation.to_s
        else
          @named_patterns[name_or_notation.to_sym] = notation.to_s
        end
        @pattern_resolution = resolution if resolution
      end

      # Stores note notation and optional parser settings.
      def notes!(notation, resolution: nil, default_octave: nil)
        @notes_notation = notation.to_s
        @note_resolution = resolution if resolution
        @default_octave = default_octave if default_octave
      end

      # Stores chord progression notation and optional octave override.
      def chords!(notation, default_octave: nil)
        @chords_notation = notation
        @default_octave = default_octave if default_octave
      end

      # Registers a sample path keyed by a symbolic name.
      def sample!(key, path, **options)
        sample_key = key.to_sym
        @samples[sample_key] = path.to_s
        @sample_options[sample_key] = normalize_sample_options!(options)
      end

      # Configures synth waveform and generator options.
      def synth!(waveform, **options)
        @waveform = waveform.to_sym
        @synth_options.merge!(options)
      end

      # Sets gain (dB) applied after rendering the track.
      def gain!(db)
        @gain_db = db.to_f
      end

      # Sets stereo pan position (-1.0..1.0).
      def pan!(position)
        @pan_position = position.to_f
      end

      # Builds and stores an ADSR envelope for sequencer notes.
      def envelope!(attack:, decay:, sustain:, release:)
        @envelope = Wavify::DSP::Envelope.new(
          attack: attack,
          decay: decay,
          sustain: sustain,
          release: release
        )
      end

      # Appends an effect configuration to the track.
      def effect!(name, **params)
        @effects << { name: name.to_sym, params: params }
      end

      # Converts DSL settings into a {Wavify::Sequencer::Track}.
      def to_sequencer_track
        Wavify::Sequencer::Track.new(
          @name,
          pattern: primary_pattern,
          note_sequence: @notes_notation,
          chord_progression: @chords_notation,
          waveform: @waveform,
          gain_db: @gain_db,
          pan_position: @pan_position,
          pattern_resolution: @pattern_resolution,
          note_resolution: @note_resolution,
          default_octave: @default_octave,
          envelope: @envelope,
          effects: effect_processors
        )
      end

      # Builds sample trigger patterns from named/primary pattern notation.
      def sample_pattern_map
        patterns = {}
        @named_patterns.each do |name, notation|
          patterns[name] = Wavify::Sequencer::Pattern.new(notation, resolution: @pattern_resolution)
        end

        if patterns.empty? && @primary_pattern && @samples.length == 1
          patterns[@samples.keys.first] = Wavify::Sequencer::Pattern.new(@primary_pattern, resolution: @pattern_resolution)
        end

        patterns
      end

      # Instantiates configured effect processor objects.
      def effect_processors
        @effects.map do |effect|
          effect_class_name = EFFECT_CLASS_NAMES[effect.fetch(:name)]
          raise Wavify::SequencerError, "unsupported effect: #{effect.fetch(:name)}" unless effect_class_name

          Wavify::Effects.const_get(effect_class_name).new(**effect.fetch(:params))
        rescue NameError
          raise Wavify::SequencerError, "effect class not found: #{effect_class_name}"
        end
      end

      private

      def normalize_sample_options!(options)
        supported = %i[gain pan trim reverse from to duration]
        unknown = options.keys - supported
        raise Wavify::SequencerError, "unsupported sample options: #{unknown.join(', ')}" unless unknown.empty?

        options.dup
      end
    end

    # :nodoc: all
    # @api private
    class TrackBuilder
      # @param track_definition [TrackDefinition]
      def initialize(track_definition)
        @track = track_definition
      end

      # Delegates pattern definition to the underlying track.
      def pattern(name_or_notation, notation = nil, resolution: nil)
        @track.pattern!(name_or_notation, notation, resolution: resolution)
      end

      # Registers a sample mapping.
      def sample(name, path, **options)
        @track.sample!(name, path, **options)
      end

      # Configures synth waveform/options.
      def synth(waveform, **options)
        @track.synth!(waveform, **options)
      end

      # Defines note notation and parser options.
      def notes(notation, resolution: nil, default_octave: nil)
        @track.notes!(notation, resolution: resolution, default_octave: default_octave)
      end

      # Defines chord notation.
      def chords(notation, default_octave: nil)
        @track.chords!(notation, default_octave: default_octave)
      end

      # Defines an ADSR envelope and validates required parameters.
      def envelope(**params)
        required = %i[attack decay sustain release]
        missing = required - params.keys
        raise Wavify::SequencerError, "missing envelope params: #{missing.join(', ')}" unless missing.empty?

        @track.envelope!(**params.slice(*required))
      end

      # Adds an effect to the track.
      def effect(name, **params)
        @track.effect!(name, **params)
      end

      # Sets track gain in dB.
      def gain(db)
        @track.gain!(db)
      end

      # Sets track pan position.
      def pan(position)
        @track.pan!(position)
      end
    end

    # :nodoc: all
    # @api private
    class ArrangementBuilder
      attr_reader :sections

      def initialize
        @sections = []
      end

      def section(name, bars:, tracks:, repeat: 1)
        raise Wavify::SequencerError, "bars must be a positive Integer" unless bars.is_a?(Integer) && bars.positive?
        raise Wavify::SequencerError, "repeat must be a positive Integer" unless repeat.is_a?(Integer) && repeat.positive?

        names = Array(tracks).map(&:to_sym)
        raise Wavify::SequencerError, "tracks must not be empty" if names.empty?

        @sections << SongDefinition::Section.new(name: name.to_sym, bars: bars, tracks: names, repeat: repeat)
      end
    end

    # :nodoc: all
    # @api private
    class Builder
      # Internal builder state used by the public {DSL.build_definition} entrypoint.
      attr_reader :format, :default_bars

      # Compiles a DSL block into a {SongDefinition}.
      #
      # @param format [Wavify::Core::Format]
      # @param tempo [Numeric]
      # @param beats_per_bar [Integer]
      # @param default_bars [Integer]
      # @return [SongDefinition]
      def self.build_definition(format:, tempo: 120, beats_per_bar: 4, swing: 0.5, default_bars: 1, &block)
        builder = new(format: format, tempo: tempo, beats_per_bar: beats_per_bar, swing: swing, default_bars: default_bars)
        builder.instance_eval(&block) if block
        builder.to_song_definition
      end

      def initialize(format:, tempo: 120, beats_per_bar: 4, swing: 0.5, default_bars: 1)
        raise Wavify::InvalidParameterError, "format must be Core::Format" unless format.is_a?(Wavify::Core::Format)

        @format = format
        @tempo = tempo.to_f
        @beats_per_bar = beats_per_bar
        @swing = validate_swing!(swing)
        @default_bars = default_bars
        @track_definitions = []
        @arrangement_sections = []
      end

      def tempo(value)
        raise Wavify::SequencerError, "tempo must be a positive Numeric" unless value.is_a?(Numeric) && value.positive?

        @tempo = value.to_f
      end

      def beats_per_bar(value)
        raise Wavify::SequencerError, "beats_per_bar must be a positive Integer" unless value.is_a?(Integer) && value.positive?

        @beats_per_bar = value
      end

      def swing(value)
        @swing = validate_swing!(value)
      end

      def bars(value)
        raise Wavify::SequencerError, "bars must be a positive Integer" unless value.is_a?(Integer) && value.positive?

        @default_bars = value
      end

      # Defines a track block and stores its compiled configuration.
      def track(name, &block)
        definition = TrackDefinition.new(name)
        TrackBuilder.new(definition).instance_eval(&block) if block
        @track_definitions << definition
        definition
      end

      # Defines arrangement sections for selective track playback by section.
      def arrange(&block)
        builder = ArrangementBuilder.new
        builder.instance_eval(&block) if block
        @arrangement_sections = builder.sections
      end

      # Finalizes and returns an immutable {SongDefinition}.
      def to_song_definition
        SongDefinition.new(
          format: @format,
          tempo: @tempo,
          beats_per_bar: @beats_per_bar,
          swing: @swing,
          default_bars: @default_bars,
          tracks: @track_definitions,
          sections: @arrangement_sections
        )
      end

      private

      def validate_swing!(value)
        unless value.is_a?(Numeric) && value.finite? && value >= 0.5 && value < 1.0
          raise Wavify::SequencerError, "swing must be a Numeric between 0.5 and 1.0"
        end

        value.to_f
      end
    end

    class << self
      # Public DSL entry that returns a compiled {SongDefinition}.
      #
      # @param format [Wavify::Core::Format]
      # @param tempo [Numeric]
      # @param beats_per_bar [Integer]
      # @param default_bars [Integer]
      # @return [SongDefinition]
      def build_definition(format:, tempo: 120, beats_per_bar: 4, swing: 0.5, default_bars: 1, &block)
        Builder.build_definition(
          format: format,
          tempo: tempo,
          beats_per_bar: beats_per_bar,
          swing: swing,
          default_bars: default_bars,
          &block
        )
      end
    end
  end

  class << self
    # Renders audio from the DSL and optionally writes it to disk.
    #
    # @param output_path [String, nil]
    # @param format [Core::Format]
    # @param tempo [Numeric]
    # @param beats_per_bar [Integer]
    # @param default_bars [Integer]
    # @return [Audio]
    def build(output_path = nil, format: Core::Format::CD_QUALITY, tempo: 120, beats_per_bar: 4, swing: 0.5, default_bars: 1,
              &block)
      song = DSL.build_definition(
        format: format,
        tempo: tempo,
        beats_per_bar: beats_per_bar,
        swing: swing,
        default_bars: default_bars,
        &block
      )

      audio = song.render(default_bars: default_bars)
      audio.write(output_path) if output_path
      audio
    end
  end
end
