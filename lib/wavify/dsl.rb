# frozen_string_literal: true

require "fileutils"
require "json"
require "pathname"

module Wavify
  # Declarative music-building DSL that compiles to sequencer tracks and audio.
  module DSL
    # Immutable compiled song definition returned by {DSL.build_definition}.
    class SongDefinition
      # Arrangement section metadata (`name`, `bars`, active `tracks`).
      Section = Struct.new(:name, :bars, :tracks, :repeat, :tempo, :beats_per_bar, :markers, keyword_init: true)

      attr_reader :format, :tempo, :beats_per_bar, :swing, :tracks, :sections, :default_bars, :random_seed

      def initialize(format:, tempo:, beats_per_bar:, swing:, default_bars:, tracks:, sections:, random_seed:)
        @format = format
        @tempo = tempo
        @beats_per_bar = beats_per_bar
        @swing = swing
        @default_bars = default_bars
        @random_seed = random_seed
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
        @tracks.map { |track| with_track_context(track) { track.to_sequencer_track } }
      end

      # Validates the compiled song without rendering audio.
      #
      # @return [true]
      def validate!
        raise Wavify::SequencerError, "song must define at least one track" if @tracks.empty?

        @tracks.each do |track|
          with_track_context(track) do
            track.to_sequencer_track
            track.sample_pattern_map
          end
        end
        timeline(default_bars: @default_bars)
        true
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
              tracks: section.tracks,
              tempo: section.tempo,
              beats_per_bar: section.beats_per_bar,
              markers: section.markers
            }
          end
        end
      end

      # Planned song duration derived from arrangement/default bars.
      #
      # @param default_bars [Integer]
      # @return [Wavify::Core::Duration]
      def duration(default_bars: @default_bars)
        Core::Duration.new(total_seconds(default_bars: default_bars))
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

      # Renders the sequencer timeline as a compact text table.
      #
      # @param default_bars [Integer]
      # @return [String]
      def timeline_text(default_bars: @default_bars)
        events = timeline(default_bars: default_bars)
        rows = events.map { |event| timeline_text_row(event) }
        (["time\tbar\ttrack\tkind\tdetail"] + rows).join("\n")
      end

      # Renders the song definition to an {Wavify::Audio} instance.
      #
      # @param default_bars [Integer]
      # @param stems [Boolean] return track-name keyed stems instead of a mix
      # @return [Wavify::Audio]
      def render(default_bars: @default_bars, stems: false)
        return render_stems(default_bars: default_bars) if stems

        playable_tracks = sequencer_tracks.select { |track| sequencer_track_playable?(track) }
        sequencer_audio = if playable_tracks.empty?
                            Wavify::Audio.silence(0, format: @format)
                          else
                            playable_names = playable_tracks.map(&:name)
                            playable_arrangement = if arrangement?
                                                     arrangement.filter_map do |section|
                                                       active_tracks = section.fetch(:tracks) & playable_names
                                                       section.merge(tracks: active_tracks) unless active_tracks.empty?
                                                     end
                                                   end
                            engine.render(
                              tracks: playable_tracks,
                              arrangement: playable_arrangement,
                              default_bars: default_bars
                            )
                          end
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
        sequencer_track = track.to_sequencer_track
        unless sequencer_track.note_sequence || sequencer_track.chord_progression
          return Wavify::Audio.silence(0, format: @format)
        end

        engine.render(
          tracks: [sequencer_track],
          arrangement: arrangement_for_stem,
          default_bars: default_bars
        )
      end

      def sequencer_track_playable?(track)
        track.note_sequence || track.chord_progression
      end

      def render_sample_tracks(default_bars:)
        rendered_tracks = @tracks.filter_map do |track|
          render_sample_track(track, default_bars: default_bars)
        end
        return nil if rendered_tracks.empty?

        Wavify::Audio.mix(*rendered_tracks)
      end

      def render_sample_track(track, default_bars:)
        patterns = with_track_context(track) { track.sample_pattern_map }
        return nil if patterns.empty?

        sections = active_sections_for(track.name, default_bars: default_bars)
        return nil if sections.empty?

        work_format = track_render_work_format
        sample_cache = {}
        events = []
        random = Random.new(@random_seed)

        sections.each do |section|
          section_engine = engine_for_section(section)
          patterns.each do |sample_key, pattern|
            sample_audio = sample_cache[sample_key] ||= load_sample_audio(track, sample_key, work_format)

            (0...section.fetch(:bars)).each do |bar_offset|
              bar_base_time = section.fetch(:start_time) + (bar_offset * section_engine.bar_duration_seconds)

              pattern.each do |step|
                next unless step.trigger?

                start_time = bar_base_time + section_engine.step_start_seconds(step.index, pattern.length)
                duration = section_engine.step_duration_at(step.index, pattern.length)
                section_engine.expand_pattern_step(step, start_time: start_time, duration: duration).each do |expanded|
                  next unless probability_hit?(expanded.fetch(:probability), random)

                  events << expanded.merge(sample_key: sample_key, sample_audio: sample_audio)
                end
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
          cursor_time = 0.0
          arrangement.each_with_object([]) do |section, result|
            section_engine = engine_for_section(section)
            if section.fetch(:tracks).include?(track_name)
          result << {
                bars: section.fetch(:bars),
                start_bar: cursor_bar,
                start_time: cursor_time,
                tempo: section.fetch(:tempo),
                beats_per_bar: section.fetch(:beats_per_bar)
              }
            end
            cursor_bar += section.fetch(:bars)
            cursor_time += section.fetch(:bars) * section_engine.bar_duration_seconds
          end
        else
          [{ bars: default_bars, start_bar: 0, start_time: 0.0, tempo: @tempo, beats_per_bar: @beats_per_bar }]
        end
      end

      def engine_for_section(section)
        Wavify::Sequencer::Engine.new(
          tempo: section.fetch(:tempo) || @tempo,
          format: @format,
          beats_per_bar: section.fetch(:beats_per_bar) || @beats_per_bar,
          swing: @swing
        )
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
        processed = pitch_sample_option(processed, options)
        processed = processed.convert(work_format)
        processed = processed.gain(options[:gain]) if options.key?(:gain)
        processed = processed.pan(options[:pan]) if options.key?(:pan)
        processed
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

      def pitch_sample_option(audio, options)
        ratio = sample_pitch_ratio(options)
        return audio if (ratio - 1.0).abs <= Float::EPSILON

        pitched_format = audio.format.with(sample_rate: (audio.sample_rate * ratio).round)
        reinterpreted = Wavify::Audio.new(Wavify::Core::SampleBuffer.new(audio.buffer.samples.dup, pitched_format))
        reinterpreted.convert(audio.format)
      end

      def sample_pitch_ratio(options)
        return validate_pitch_ratio!(options.fetch(:pitch_ratio)) if options.key?(:pitch_ratio)
        return 1.0 unless options.key?(:pitch)

        pitch = options.fetch(:pitch)
        raise Wavify::SequencerError, "sample pitch must be Numeric semitones" unless pitch.is_a?(Numeric) && pitch.finite?

        2.0**(pitch.to_f / 12.0)
      end

      def validate_pitch_ratio!(value)
        unless value.is_a?(Numeric) && value.finite? && value.positive?
          raise Wavify::SequencerError, "sample pitch_ratio must be a positive Numeric"
        end

        value.to_f
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

      def probability_hit?(probability, random)
        return false if probability <= 0.0
        return true if probability >= 1.0

        random.rand < probability
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

      def total_seconds(default_bars:)
        return total_bars(default_bars: default_bars) * engine.bar_duration_seconds unless arrangement?

        arrangement.sum do |section|
          section_engine = Wavify::Sequencer::Engine.new(
            tempo: section.fetch(:tempo) || @tempo,
            format: @format,
            beats_per_bar: section.fetch(:beats_per_bar) || @beats_per_bar,
            swing: @swing
          )
          section.fetch(:bars) * section_engine.bar_duration_seconds
        end
      end

      def repeated_section_name(name, repeat_index)
        return name if repeat_index.zero?

        :"#{name}_#{repeat_index + 1}"
      end

      def with_track_context(track)
        yield
      rescue Wavify::Error => e
        message = e.message.to_s
        label = "track :#{track.name}"
        raise if message.start_with?("#{label}:")

        raise Wavify::SequencerError, "#{label}: #{message}"
      end

      def timeline_text_row(event)
        [
          Kernel.format("%.3f", event.fetch(:start_time)),
          event.fetch(:bar),
          event.fetch(:track),
          event.fetch(:kind),
          timeline_text_detail(event)
        ].join("\t")
      end

      def timeline_text_detail(event)
        case event.fetch(:kind)
        when :trigger
          detail = "step=#{event.fetch(:step_index)} velocity=#{Kernel.format('%.2f', event.fetch(:velocity))}"
          detail += " probability=#{Kernel.format('%.2f', event.fetch(:probability))}" if event.fetch(:probability, 1.0) < 1.0
          detail += " ratchet=#{event.fetch(:ratchet_index) + 1}/#{event.fetch(:ratchet_count)}" if event.fetch(:ratchet_count, 1) > 1
          detail
        when :note
          "step=#{event.fetch(:step_index)} midi=#{event.fetch(:midi_notes).join(',')}"
        when :chord
          "chord=#{event.fetch(:chord)} midi=#{event.fetch(:midi_notes).join(',')}"
        when :marker
          "marker=#{event.fetch(:marker)} section=#{event.fetch(:section)}"
        else
          "step=#{event.fetch(:step_index)}"
        end
      end
    end

    # :nodoc: all
    # @api private
    class TrackDefinition
      # Internal mutable track state compiled from DSL blocks.
      #
      # Readers are used by {SongDefinition} rendering and sequencer conversion.
      attr_reader :name, :sample_folder, :waveform, :gain_db, :pan_position, :pattern_resolution, :note_resolution,
                  :default_octave, :envelope, :notes_notation, :chords_notation, :effects, :samples,
                  :sample_options, :named_patterns, :synth_options, :key_root, :scale, :chord_voicing

      def initialize(name, sample_folder: nil, key_root: nil, scale: nil)
        @name = name.to_sym
        @sample_folder = sample_folder
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
        @key_root = key_root
        @scale = scale
        @chord_voicing = nil
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
      def chords!(notation, default_octave: nil, voicing: nil)
        @chords_notation = notation
        @default_octave = default_octave if default_octave
        @chord_voicing = voicing.to_sym if voicing
      end

      # Stores note quantization key/scale settings.
      def key!(root, scale = :major)
        @key_root = root
        @scale = scale
      end

      # Registers a sample path keyed by a symbolic name.
      def sample!(key, path = nil, **options)
        sample_key = key.to_sym
        @samples[sample_key] = resolve_sample_path(sample_key, path)
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
          effects: effect_processors,
          key: @key_root,
          scale: @scale,
          chord_voicing: @chord_voicing
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
        elsif patterns.empty? && @primary_pattern && @samples.length > 1
          raise Wavify::SequencerError, "primary sample pattern is ambiguous with multiple samples; use named patterns"
        end

        patterns
      end

      # Instantiates configured effect processor objects.
      def effect_processors
        @effects.map do |effect|
          Wavify::Effects.build(effect.fetch(:name), **effect.fetch(:params))
        rescue Wavify::Error => e
          raise Wavify::SequencerError, e.message
        end
      end

      private

      def normalize_sample_options!(options)
        supported = %i[gain pan trim reverse from to duration pitch pitch_ratio]
        unknown = options.keys - supported
        raise Wavify::SequencerError, "unsupported sample options: #{unknown.join(', ')}" unless unknown.empty?
        validate_sample_numeric_option!(options, :pitch) if options.key?(:pitch)
        validate_sample_numeric_option!(options, :pitch_ratio, positive: true) if options.key?(:pitch_ratio)

        options.dup
      end

      def validate_sample_numeric_option!(options, key, positive: false)
        value = options.fetch(key)
        valid = value.is_a?(Numeric) && value.finite? && (!positive || value.positive?)
        return if valid

        requirement = positive ? "a positive Numeric" : "Numeric"
        raise Wavify::SequencerError, "sample #{key} must be #{requirement}"
      end

      def resolve_sample_path(sample_key, path)
        source = path.nil? ? "#{sample_key}.wav" : path.to_s
        return source unless @sample_folder && !Pathname.new(source).absolute?

        File.join(@sample_folder, source)
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
      def sample(name, path = nil, **options)
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
      def chords(notation, default_octave: nil, voicing: nil)
        @track.chords!(notation, default_octave: default_octave, voicing: voicing)
      end

      # Quantizes note and chord pitches to a key/scale.
      def key(root, scale = :major)
        @track.key!(root, scale)
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

      def section(name, bars:, tracks:, repeat: 1, tempo: nil, beats_per_bar: nil, markers: [])
        raise Wavify::SequencerError, "bars must be a positive Integer" unless bars.is_a?(Integer) && bars.positive?
        raise Wavify::SequencerError, "repeat must be a positive Integer" unless repeat.is_a?(Integer) && repeat.positive?
        raise Wavify::SequencerError, "tempo must be a positive Numeric" if tempo && !(tempo.is_a?(Numeric) && tempo.positive?)
        if beats_per_bar && !(beats_per_bar.is_a?(Integer) && beats_per_bar.positive?)
          raise Wavify::SequencerError, "beats_per_bar must be a positive Integer"
        end

        names = Array(tracks).map(&:to_sym)
        raise Wavify::SequencerError, "tracks must not be empty" if names.empty?

        @sections << SongDefinition::Section.new(
          name: name.to_sym,
          bars: bars,
          tracks: names,
          repeat: repeat,
          tempo: tempo,
          beats_per_bar: beats_per_bar,
          markers: Array(markers).map(&:to_sym)
        )
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
      def self.build_definition(format:, tempo: 120, beats_per_bar: 4, swing: 0.5, default_bars: 1,
                                random_seed: Random.new_seed, &block)
        builder = new(
          format: format,
          tempo: tempo,
          beats_per_bar: beats_per_bar,
          swing: swing,
          default_bars: default_bars,
          random_seed: random_seed
        )
        builder.instance_eval(&block) if block
        builder.to_song_definition
      end

      def initialize(format:, tempo: 120, beats_per_bar: 4, swing: 0.5, default_bars: 1,
                     random_seed: Random.new_seed)
        raise Wavify::InvalidParameterError, "format must be Core::Format" unless format.is_a?(Wavify::Core::Format)

        @format = format
        @tempo = validate_tempo!(tempo)
        @beats_per_bar = validate_beats_per_bar!(beats_per_bar)
        @swing = validate_swing!(swing)
        @default_bars = validate_default_bars!(default_bars)
        @random_seed = validate_random_seed!(random_seed)
        @sample_folder = nil
        @key_root = nil
        @scale = nil
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

      def sample_folder(path)
        raise Wavify::SequencerError, "sample_folder must be a String" unless path.is_a?(String) && !path.empty?

        @sample_folder = path
      end

      def key(root, scale = :major)
        @key_root = root
        @scale = scale
      end

      def preset(name, **options)
        case name.to_sym
        when :lofi_drums
          lofi_drums_preset(**options)
        else
          raise Wavify::SequencerError, "unsupported preset: #{name.inspect}"
        end
      end

      # Defines a track block and stores its compiled configuration.
      def track(name, sample_folder: @sample_folder, &block)
        normalized_name = name.to_sym
        if @track_definitions.any? { |definition| definition.name == normalized_name }
          raise Wavify::SequencerError, "duplicate track name: #{normalized_name}"
        end

        definition = TrackDefinition.new(normalized_name, sample_folder: sample_folder, key_root: @key_root, scale: @scale)
        begin
          TrackBuilder.new(definition).instance_eval(&block) if block
        rescue Wavify::Error => e
          raise Wavify::SequencerError, "track :#{definition.name}: #{e.message}"
        end
        @track_definitions << definition
        definition
      end

      def lofi_drums_preset(name: :lofi_drums, sample_folder: @sample_folder)
        track(name, sample_folder: sample_folder) do
          pattern :kick, "x---x---x---x---"
          pattern :snare, "----x-------x---"
          pattern :hat, "x-x-x-x-x-x-x-x-"
          sample :kick, "kick.wav", gain: -2, trim: true
          sample :snare, "snare.wav", gain: -4, trim: true
          sample :hat, "hat.wav", gain: -9, pan: 0.15, trim: true
          effect :compressor, threshold: -18, ratio: 2.5, attack: 0.005, release: 0.08, makeup_gain: 2
          gain(-3)
        end
      end

      # Defines arrangement sections for selective track playback by section.
      def arrange(&block)
        builder = ArrangementBuilder.new
        begin
          builder.instance_eval(&block) if block
        rescue Wavify::SequencerError => e
          raise Wavify::SequencerError, "arrangement: #{e.message}"
        end
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
          sections: @arrangement_sections,
          random_seed: @random_seed
        )
      end

      private

      def validate_swing!(value)
        unless value.is_a?(Numeric) && value.finite? && value >= 0.5 && value < 1.0
          raise Wavify::SequencerError, "swing must be a Numeric between 0.5 and 1.0"
        end

        value.to_f
      end

      def validate_tempo!(value)
        raise Wavify::SequencerError, "tempo must be a positive Numeric" unless value.is_a?(Numeric) && value.positive?

        value.to_f
      end

      def validate_beats_per_bar!(value)
        raise Wavify::SequencerError, "beats_per_bar must be a positive Integer" unless value.is_a?(Integer) && value.positive?

        value
      end

      def validate_default_bars!(value)
        raise Wavify::SequencerError, "bars must be a positive Integer" unless value.is_a?(Integer) && value.positive?

        value
      end

      def validate_random_seed!(value)
        raise Wavify::SequencerError, "random_seed must be an Integer" unless value.is_a?(Integer)

        value
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
      def build_definition(format:, tempo: 120, beats_per_bar: 4, swing: 0.5, default_bars: 1,
                           random_seed: Random.new_seed, &block)
        Builder.build_definition(
          format: format,
          tempo: tempo,
          beats_per_bar: beats_per_bar,
          swing: swing,
          default_bars: default_bars,
          random_seed: random_seed,
          &block
        )
      end

      # Validates a DSL block without rendering audio.
      #
      # @return [true]
      def validate(format:, tempo: 120, beats_per_bar: 4, swing: 0.5, default_bars: 1,
                   random_seed: Random.new_seed, &block)
        build_definition(
          format: format,
          tempo: tempo,
          beats_per_bar: beats_per_bar,
          swing: swing,
          default_bars: default_bars,
          random_seed: random_seed,
          &block
        ).validate!
      end

      # Registers an effect factory for DSL `effect :name` usage.
      #
      # @param name [Symbol, String]
      # @param factory [Class, #call]
      # @return [Class, #call]
      def effect(name, factory = nil, &block)
        Wavify::Effects.register(name, factory, &block)
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
              random_seed: Random.new_seed, &block)
      song = DSL.build_definition(
        format: format,
        tempo: tempo,
        beats_per_bar: beats_per_bar,
        swing: swing,
        default_bars: default_bars,
        random_seed: random_seed,
        &block
      )

      audio = song.render(default_bars: default_bars)
      audio.write(output_path) if output_path
      audio
    end
  end
end
