# frozen_string_literal: true

module Wavify
  module Sequencer
    # Schedules sequencer tracks and renders them into audio.
    class Engine
      # Default beats-per-bar value used when omitted.
      DEFAULT_BEATS_PER_BAR = 4

      attr_reader :tempo, :format, :beats_per_bar

      def initialize(tempo:, format: Wavify::Core::Format::CD_QUALITY, beats_per_bar: DEFAULT_BEATS_PER_BAR)
        @tempo = validate_tempo!(tempo)
        @format = validate_format!(format)
        @beats_per_bar = validate_beats_per_bar!(beats_per_bar)
      end

      # @return [Float] seconds per beat at the current tempo
      def seconds_per_beat
        60.0 / @tempo
      end

      # @return [Float] duration of one bar in seconds
      def bar_duration_seconds
        seconds_per_beat * @beats_per_bar
      end

      def step_duration_seconds(resolution)
        raise SequencerError, "resolution must be a positive Integer" unless resolution.is_a?(Integer) && resolution.positive?

        bar_duration_seconds / resolution.to_f
      end

      def timeline_for_track(track, bars:, start_bar: 0)
        raise SequencerError, "track must be a Sequencer::Track" unless track.is_a?(Track)
        raise SequencerError, "bars must be a positive Integer" unless bars.is_a?(Integer) && bars.positive?
        raise SequencerError, "start_bar must be a non-negative Integer" unless start_bar.is_a?(Integer) && start_bar >= 0

        events = []
        events.concat(schedule_pattern_events(track, bars: bars, start_bar: start_bar)) if track.pattern?
        events.concat(schedule_note_events(track, bars: bars, start_bar: start_bar)) if track.notes?
        events.concat(schedule_chord_events(track, bars: bars, start_bar: start_bar)) if track.chords?
        events.sort_by { |event| [event[:start_time], event[:kind].to_s] }
      end

      # Builds a combined event timeline for tracks and optional arrangement.
      #
      # @param tracks [Array<Wavify::Sequencer::Track>]
      # @param arrangement [Array<Hash>, nil]
      # @param default_bars [Integer]
      # @return [Array<Hash>]
      def build_timeline(tracks:, arrangement: nil, default_bars: 1)
        track_map = normalize_tracks(tracks)

        if arrangement
          build_arranged_timeline(track_map, arrangement)
        else
          raise SequencerError, "default_bars must be a positive Integer" unless default_bars.is_a?(Integer) && default_bars.positive?

          events = track_map.values.flat_map do |track|
            timeline_for_track(track, bars: default_bars)
          end
          events.sort_by { |event| [event[:start_time], event[:track].to_s] }
        end
      end

      # Renders tracks into a mixed audio object.
      #
      # @param tracks [Array<Wavify::Sequencer::Track>]
      # @param arrangement [Array<Hash>, nil]
      # @param default_bars [Integer]
      # @return [Wavify::Audio]
      def render(tracks:, arrangement: nil, default_bars: 1)
        track_map = normalize_tracks(tracks)
        sections = arrangement ? normalize_arrangement(arrangement, track_map) : nil

        rendered_audios = if sections
                            render_arranged_tracks(track_map, sections)
                          else
                            track_map.values.filter_map { |track| render_track_audio(track, bars: default_bars) }
                          end

        return Wavify::Audio.silence(0.0, format: @format) if rendered_audios.empty?

        Wavify::Audio.mix(*rendered_audios)
      end

      private

      def normalize_tracks(tracks)
        list = tracks.is_a?(Array) ? tracks : Array(tracks)
        raise SequencerError, "tracks must not be empty" if list.empty?

        list.each_with_object({}) do |track, map|
          raise SequencerError, "track must be a Sequencer::Track" unless track.is_a?(Track)

          map[track.name] = track
        end
      end

      def normalize_arrangement(arrangement, track_map)
        raise SequencerError, "arrangement must be an Array" unless arrangement.is_a?(Array)

        cursor_bar = 0
        arrangement.map do |section|
          raise SequencerError, "section must be a Hash" unless section.is_a?(Hash)

          name = section.fetch(:name, "section_#{cursor_bar}").to_sym
          bars = section.fetch(:bars)
          raise SequencerError, "section bars must be a positive Integer" unless bars.is_a?(Integer) && bars.positive?

          track_names = Array(section.fetch(:tracks)).map(&:to_sym)
          raise SequencerError, "section tracks must not be empty" if track_names.empty?

          unknown = track_names - track_map.keys
          raise SequencerError, "unknown tracks in section #{name}: #{unknown.join(', ')}" unless unknown.empty?

          normalized = { name: name, bars: bars, tracks: track_names, start_bar: cursor_bar }
          cursor_bar += bars
          normalized
        end
      end

      def build_arranged_timeline(track_map, arrangement)
        sections = normalize_arrangement(arrangement, track_map)
        events = sections.flat_map do |section|
          section[:tracks].flat_map do |track_name|
            timeline_for_track(track_map.fetch(track_name), bars: section[:bars], start_bar: section[:start_bar])
          end
        end
        events.sort_by { |event| [event[:start_time], event[:track].to_s] }
      end

      def render_arranged_tracks(track_map, sections)
        sections.flat_map do |section|
          section[:tracks].filter_map do |track_name|
            render_track_audio(track_map.fetch(track_name), bars: section[:bars], start_bar: section[:start_bar])
          end
        end
      end

      def render_track_audio(track, bars:, start_bar: 0)
        events = timeline_for_track(track, bars: bars, start_bar: start_bar)
        note_events = events.select { |event| %i[note chord].include?(event[:kind]) }
        return nil if note_events.empty?

        track_format = @format.channels == 2 ? @format : @format.with(channels: 2)
        total_end_time = note_events.map { |event| event[:start_time] + event[:duration] }.max || 0.0
        audio = Wavify::Audio.silence(total_end_time, format: track_format.with(sample_format: :float, bit_depth: 32))
        mixed = audio.buffer.samples.dup

        note_events.each do |event|
          frequencies = event[:midi_notes].map { |midi| midi_to_frequency(midi) }
          note_audio = render_chord_tone(frequencies, event[:duration], track, track_format.with(sample_format: :float, bit_depth: 32))
          start_frame = (event[:start_time] * track_format.sample_rate).round
          start_index = start_frame * track_format.channels

          note_audio.buffer.samples.each_with_index do |sample, index|
            target_index = start_index + index
            break if target_index >= mixed.length

            mixed[target_index] += sample
          end
        end

        mixed.map! { |sample| sample.clamp(-1.0, 1.0) }
        rendered = Wavify::Audio.new(Wavify::Core::SampleBuffer.new(mixed, track_format.with(sample_format: :float, bit_depth: 32)))
        rendered = rendered.gain(track.gain_db) if track.gain_db != 0.0
        rendered = rendered.pan(track.pan_position) if track.pan_position != 0.0
        rendered = apply_track_effects(rendered, track.effects) if track.effects?
        rendered.convert(@format)
      end

      def render_chord_tone(frequencies, duration, track, format)
        note_audios = frequencies.map do |frequency|
          tone = Wavify::Audio.tone(frequency: frequency, duration: duration, format: format, waveform: track.waveform)
          if track.envelope
            tone.apply(lambda do |buffer|
              track.envelope.apply(buffer, note_on_duration: duration)
            end)
          else
            tone
          end
        end

        Wavify::Audio.mix(*note_audios)
      end

      def schedule_pattern_events(track, bars:, start_bar:)
        step_duration = step_duration_seconds(track.pattern.length)

        (0...bars).flat_map do |bar_offset|
          track.pattern.filter(&:trigger?).map do |step|
            absolute_bar = start_bar + bar_offset
            start_time = (absolute_bar * bar_duration_seconds) + (step.index * step_duration)
            {
              kind: :trigger,
              track: track.name,
              bar: absolute_bar,
              step_index: step.index,
              start_time: start_time,
              duration: step_duration,
              velocity: step.velocity
            }
          end
        end
      end

      def schedule_note_events(track, bars:, start_bar:)
        base_step_duration = step_duration_seconds(track.note_resolution)

        (0...bars).flat_map do |bar_offset|
          track.note_sequence.each_with_object([]) do |event, result|
            next if event.rest?

            absolute_bar = start_bar + bar_offset
            start_time = (absolute_bar * bar_duration_seconds) + (event.index * base_step_duration)
            result << {
              kind: :note,
              track: track.name,
              bar: absolute_bar,
              step_index: event.index,
              start_time: start_time,
              duration: base_step_duration,
              midi_notes: [event.midi_note]
            }
          end
        end
      end

      def schedule_chord_events(track, bars:, start_bar:)
        progression = track.chord_progression
        return [] unless progression

        (0...bars).map do |bar_offset|
          chord = progression[bar_offset % progression.length]
          absolute_bar = start_bar + bar_offset
          {
            kind: :chord,
            track: track.name,
            bar: absolute_bar,
            step_index: 0,
            start_time: absolute_bar * bar_duration_seconds,
            duration: bar_duration_seconds,
            midi_notes: chord.fetch(:midi_notes),
            chord: chord.fetch(:token)
          }
        end
      end

      def midi_to_frequency(midi_note)
        440.0 * (2.0**((midi_note - 69) / 12.0))
      end

      def apply_track_effects(audio, effects)
        effects.reduce(audio) { |current, effect| current.apply(effect) }
      end

      def validate_tempo!(tempo)
        raise SequencerError, "tempo must be a positive Numeric" unless tempo.is_a?(Numeric) && tempo.positive?

        tempo.to_f
      end

      def validate_format!(format)
        raise SequencerError, "format must be a Core::Format" unless format.is_a?(Wavify::Core::Format)

        format
      end

      def validate_beats_per_bar!(beats_per_bar)
        raise SequencerError, "beats_per_bar must be a positive Integer" unless beats_per_bar.is_a?(Integer) && beats_per_bar.positive?

        beats_per_bar
      end
    end
  end
end
