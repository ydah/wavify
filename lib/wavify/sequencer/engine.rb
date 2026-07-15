# frozen_string_literal: true

module Wavify
  module Sequencer
    # Schedules sequencer tracks and renders them into audio.
    class Engine
      # Default beats-per-bar value used when omitted.
      DEFAULT_BEATS_PER_BAR = 4

      attr_reader :tempo, :format, :beats_per_bar, :swing

      def initialize(tempo:, format: Wavify::Core::Format::CD_QUALITY, beats_per_bar: DEFAULT_BEATS_PER_BAR, swing: 0.5)
        @tempo = validate_tempo!(tempo)
        @format = validate_format!(format)
        @beats_per_bar = validate_beats_per_bar!(beats_per_bar)
        @swing = validate_swing!(swing)
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

      def step_start_seconds(index, resolution)
        base_duration = step_duration_seconds(resolution)
        return index * base_duration if straight_timing?(resolution)

        pair_duration = base_duration * 2.0
        ((index / 2) * pair_duration) + (index.even? ? 0.0 : pair_duration * @swing)
      end

      def step_duration_at(index, resolution)
        base_duration = step_duration_seconds(resolution)
        return base_duration if straight_timing?(resolution)

        pair_duration = base_duration * 2.0
        pair_duration * (index.even? ? @swing : (1.0 - @swing))
      end

      def expand_pattern_step(step, start_time:, duration:)
        ratchet = step.ratchet || 1
        event_duration = duration / ratchet
        Array.new(ratchet) do |ratchet_index|
          {
            start_time: start_time + (event_duration * ratchet_index),
            duration: event_duration,
            velocity: step.velocity,
            probability: step.probability || 1.0,
            ratchet_index: ratchet_index,
            ratchet_count: ratchet
          }
        end
      end

      def timeline_for_track(track, bars:, start_bar: 0, start_time: nil)
        raise SequencerError, "track must be a Sequencer::Track" unless track.is_a?(Track)
        raise SequencerError, "bars must be a positive Integer" unless bars.is_a?(Integer) && bars.positive?
        raise SequencerError, "start_bar must be a non-negative Integer" unless start_bar.is_a?(Integer) && start_bar >= 0
        if start_time && !(start_time.is_a?(Numeric) && start_time >= 0)
          raise SequencerError, "start_time must be a non-negative Numeric"
        end

        events = []
        events.concat(schedule_pattern_events(track, bars: bars, start_bar: start_bar, start_time: start_time)) if track.pattern?
        events.concat(schedule_note_events(track, bars: bars, start_bar: start_bar, start_time: start_time)) if track.notes?
        events.concat(schedule_chord_events(track, bars: bars, start_bar: start_bar, start_time: start_time)) if track.chords?
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

        Wavify::Audio.mix(*rendered_audios, strategy: :headroom)
      end

      private

      def normalize_tracks(tracks)
        list = tracks.is_a?(Array) ? tracks : Array(tracks)
        raise SequencerError, "tracks must not be empty" if list.empty?

        list.each_with_object({}) do |track, map|
          raise SequencerError, "track must be a Sequencer::Track" unless track.is_a?(Track)
          raise SequencerError, "duplicate track name: #{track.name}" if map.key?(track.name)

          map[track.name] = track
        end
      end

      def normalize_arrangement(arrangement, track_map)
        raise SequencerError, "arrangement must be an Array" unless arrangement.is_a?(Array)

        cursor_bar = 0
        cursor_time = 0.0
        arrangement.flat_map do |section|
          raise SequencerError, "section must be a Hash" unless section.is_a?(Hash)

          name = section.fetch(:name, "section_#{cursor_bar}").to_sym
          bars = section.fetch(:bars)
          raise SequencerError, "section bars must be a positive Integer" unless bars.is_a?(Integer) && bars.positive?
          repeat = section.fetch(:repeat, 1)
          raise SequencerError, "section repeat must be a positive Integer" unless repeat.is_a?(Integer) && repeat.positive?
          tempo = normalize_section_tempo(section[:tempo] || @tempo)
          beats_per_bar = validate_beats_per_bar!(section[:beats_per_bar] || @beats_per_bar)
          markers = normalize_section_markers(section.fetch(:markers, []))

          track_names = Array(section.fetch(:tracks)).map(&:to_sym)
          unknown = track_names - track_map.keys
          raise SequencerError, "unknown tracks in section #{name}: #{unknown.join(', ')}" unless unknown.empty?

          Array.new(repeat) do |repeat_index|
            section_engine = self.class.new(tempo: tempo, format: @format, beats_per_bar: beats_per_bar, swing: @swing)
            normalized = {
              name: repeated_section_name(name, repeat_index),
              bars: bars,
              tracks: track_names,
              start_bar: cursor_bar,
              start_time: cursor_time,
              tempo: tempo,
              beats_per_bar: beats_per_bar,
              markers: markers
            }
            cursor_bar += bars
            cursor_time += bars * section_engine.bar_duration_seconds
            normalized
          end
        end
      end

      def build_arranged_timeline(track_map, arrangement)
        sections = normalize_arrangement(arrangement, track_map)
        events = sections.flat_map do |section|
          section_engine = engine_for_section(section)
          section_events = section[:tracks].flat_map do |track_name|
            section_engine.timeline_for_track(
              track_map.fetch(track_name),
              bars: section[:bars],
              start_bar: section[:start_bar],
              start_time: section[:start_time]
            )
          end
          section_events + marker_events_for_section(section)
        end
        events.sort_by { |event| [event[:start_time], event[:track].to_s] }
      end

      def render_arranged_tracks(track_map, sections)
        sections.flat_map do |section|
          section_engine = engine_for_section(section)
          section[:tracks].filter_map do |track_name|
            section_engine.send(
              :render_track_audio,
              track_map.fetch(track_name),
              bars: section[:bars],
              start_bar: section[:start_bar],
              start_time: section[:start_time]
            )
          end
        end
      end

      def render_track_audio(track, bars:, start_bar: 0, start_time: nil)
        events = timeline_for_track(track, bars: bars, start_bar: start_bar, start_time: start_time)
        note_events = events.select { |event| %i[note chord].include?(event[:kind]) }
        if note_events.empty? && events.any? { |event| event[:kind] == :trigger }
          raise SequencerError, "trigger patterns require a sample-backed DSL track; synth tracks must use notes or chords"
        end
        return nil if note_events.empty?

        track_format = @format.channels == 2 ? @format : @format.with(channels: 2)
        release_seconds = track.envelope&.release || 0.0
        total_end_time = note_events.map { |event| event[:start_time] + event[:duration] + release_seconds }.max || 0.0
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

        Wavify::DSP::Headroom.apply!(
          mixed,
          channels: track_format.channels,
          sample_rate: track_format.sample_rate
        )
        rendered = Wavify::Audio.new(Wavify::Core::SampleBuffer.new(mixed, track_format.with(sample_format: :float, bit_depth: 32)))
        rendered = rendered.gain(track.gain_db) if track.gain_db != 0.0
        rendered = rendered.pan(track.pan_position) if track.pan_position != 0.0
        rendered = apply_track_effects(rendered, track.effects) if track.effects?
        rendered.convert(@format)
      end

      def render_chord_tone(frequencies, duration, track, format)
        rendered_duration = duration + (track.envelope&.release || 0.0)
        note_audios = frequencies.map do |frequency|
          tone = Wavify::Audio.tone(frequency: frequency, duration: rendered_duration, format: format, waveform: track.waveform)
          if track.envelope
            tone.apply(lambda do |buffer|
              track.envelope.apply(buffer, note_on_duration: duration)
            end)
          else
            tone
          end
        end

        Wavify::Audio.mix(*note_audios, strategy: :headroom)
      end

      def schedule_pattern_events(track, bars:, start_bar:, start_time:)
        resolution = track.pattern.length

        (0...bars).flat_map do |bar_offset|
          track.pattern.filter(&:trigger?).flat_map do |step|
            absolute_bar = start_bar + bar_offset
            event_start_time = bar_start_seconds(absolute_bar, bar_offset, start_time) + step_start_seconds(step.index, resolution)
            duration = step_duration_at(step.index, resolution)
            expand_pattern_step(step, start_time: event_start_time, duration: duration).map do |event|
              event.merge(kind: :trigger, track: track.name, bar: absolute_bar, step_index: step.index)
            end
          end
        end
      end

      def schedule_note_events(track, bars:, start_bar:, start_time:)
        resolution = track.note_resolution

        (0...bars).flat_map do |bar_offset|
          result = []
          events = track.note_sequence.events
          index = 0
          while index < events.length
            event = events.fetch(index)
            index += 1
            next if event.rest?

            absolute_bar = start_bar + bar_offset
            event_start_time = bar_start_seconds(absolute_bar, bar_offset, start_time) + step_start_seconds(event.index, resolution)
            duration, index = note_duration_and_next_index(events, index - 1, resolution)
            result << {
              kind: :note,
              track: track.name,
              bar: absolute_bar,
              step_index: event.index,
              start_time: event_start_time,
              duration: duration,
              midi_notes: [track.quantize_midi_note(event.midi_note)]
            }
          end
          result
        end
      end

      def note_duration_and_next_index(events, start_index, resolution)
        event = events.fetch(start_index)
        duration = note_event_duration(event, resolution)
        cursor = start_index

        while event.tie? && cursor + 1 < events.length
          next_event = events.fetch(cursor + 1)
          break if next_event.rest? || next_event.midi_note != event.midi_note

          duration += note_event_duration(next_event, resolution)
          cursor += 1
          event = next_event
        end

        [duration, cursor + 1]
      end

      def note_event_duration(event, resolution)
        if event.duration_denominator
          return (bar_duration_seconds / event.duration_denominator.to_f) * event.duration_multiplier.to_f
        end

        step_duration_at(event.index, resolution)
      end

      def schedule_chord_events(track, bars:, start_bar:, start_time:)
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
            start_time: bar_start_seconds(absolute_bar, bar_offset, start_time),
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

      def validate_swing!(swing)
        unless swing.is_a?(Numeric) && swing.finite? && swing >= 0.5 && swing < 1.0
          raise SequencerError, "swing must be a Numeric between 0.5 and 1.0"
        end

        swing.to_f
      end

      def straight_timing?(resolution)
        (@swing - 0.5).abs <= Float::EPSILON || resolution.odd?
      end

      def repeated_section_name(name, repeat_index)
        return name if repeat_index.zero?

        :"#{name}_#{repeat_index + 1}"
      end

      def bar_start_seconds(absolute_bar, bar_offset, start_time)
        return (start_time.to_f + (bar_offset * bar_duration_seconds)) if start_time

        absolute_bar * bar_duration_seconds
      end

      def engine_for_section(section)
        self.class.new(
          tempo: section[:tempo] || @tempo,
          format: @format,
          beats_per_bar: section[:beats_per_bar] || @beats_per_bar,
          swing: @swing
        )
      end

      def marker_events_for_section(section)
        section.fetch(:markers, []).map do |marker|
          {
            kind: :marker,
            track: :arrangement,
            bar: section.fetch(:start_bar),
            step_index: 0,
            start_time: section.fetch(:start_time),
            duration: 0.0,
            marker: marker,
            section: section.fetch(:name)
          }
        end
      end

      def normalize_section_tempo(value)
        validate_tempo!(value)
      end

      def normalize_section_markers(markers)
        Array(markers).map do |marker|
          value = marker.to_sym
          raise SequencerError, "section markers must not be empty" if value.to_s.empty?

          value
        rescue NoMethodError
          raise SequencerError, "section markers must be Symbol/String"
        end
      end
    end
  end
end
