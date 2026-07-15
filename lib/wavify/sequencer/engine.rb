# frozen_string_literal: true

module Wavify
  module Sequencer
    # Schedules sequencer tracks and renders them into audio.
    class Engine
      # Default beats-per-bar value used when omitted.
      DEFAULT_BEATS_PER_BAR = 4
      # Maximum bars accepted by a single render request.
      MAX_BARS = 100_000
      # Maximum structural sections accepted before repeat expansion.
      MAX_ARRANGEMENT_SECTIONS = 10_000
      # Maximum sections produced by lazy arrangement repeat expansion.
      MAX_EXPANDED_SECTIONS = 100_000
      # Maximum repeat count on one arrangement section.
      MAX_SECTION_REPEAT = 10_000
      # Maximum scheduled timeline events in one build.
      MAX_EVENTS = 1_000_000
      # Final sequencer ceiling leaves conversion margin below digital full scale.
      MASTER_CEILING_DB = -0.1

      attr_reader :tempo, :format, :beats_per_bar, :swing

      def initialize(tempo:, format: Wavify::Core::Format::CD_QUALITY, beats_per_bar: DEFAULT_BEATS_PER_BAR, swing: 0.5)
        @tempo = validate_tempo!(tempo)
        @format = validate_format!(format)
        @beats_per_bar = validate_beats_per_bar!(beats_per_bar)
        @swing = validate_swing!(swing)
        @section_engine_cache = {}
      end

      # @return [Float] seconds per beat at the current tempo
      def seconds_per_beat
        seconds_per_beat_rational.to_f
      end

      # @return [Float] duration of one bar in seconds
      def bar_duration_seconds
        bar_duration_time.to_f
      end

      def step_duration_seconds(resolution)
        raise SequencerError, "resolution must be a positive Integer" unless resolution.is_a?(Integer) && resolution.positive?

        step_duration_time(resolution).to_f
      end

      def step_start_seconds(index, resolution)
        step_start_time(index, resolution).to_f
      end

      def step_duration_at(index, resolution)
        step_duration_time_at(index, resolution).to_f
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
        unless bars.is_a?(Integer) && bars.between?(1, MAX_BARS)
          raise SequencerError, "bars must be an Integer in 1..#{MAX_BARS}"
        end
        raise SequencerError, "start_bar must be a non-negative Integer" unless start_bar.is_a?(Integer) && start_bar >= 0
        if start_time && !(start_time.is_a?(Numeric) && start_time.respond_to?(:finite?) && start_time.finite? && start_time >= 0)
          raise SequencerError, "start_time must be a non-negative finite Numeric"
        end

        events = []
        events.concat(schedule_pattern_events(track, bars: bars, start_bar: start_bar, start_time: start_time)) if track.pattern?
        events.concat(schedule_note_events(track, bars: bars, start_bar: start_bar, start_time: start_time)) if track.notes?
        events.concat(schedule_chord_events(track, bars: bars, start_bar: start_bar, start_time: start_time)) if track.chords?
        raise SequencerError, "timeline exceeds #{MAX_EVENTS} events" if events.length > MAX_EVENTS

        events.map { |event| decorate_event_timing(event) }
              .sort_by { |event| [event[:start_frame], event[:kind].to_s] }
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
          unless default_bars.is_a?(Integer) && default_bars.between?(1, MAX_BARS)
            raise SequencerError, "default_bars must be an Integer in 1..#{MAX_BARS}"
          end

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

        master_audio(rendered_audios)
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
        if arrangement.length > MAX_ARRANGEMENT_SECTIONS
          raise SequencerError, "arrangement exceeds #{MAX_ARRANGEMENT_SECTIONS} sections"
        end

        normalized_sections = arrangement.map { |section| normalize_arrangement_section(section, track_map) }
        expanded_count = normalized_sections.sum { |section| section.fetch(:repeat) }
        if expanded_count > MAX_EXPANDED_SECTIONS
          raise SequencerError, "expanded arrangement exceeds #{MAX_EXPANDED_SECTIONS} sections"
        end

        Enumerator.new do |yielder|
          cursor_bar = 0
          cursor_time = Rational(0, 1)
          normalized_sections.each do |section|
            name = section[:name] || :"section_#{cursor_bar}"
            section_engine = engine_for_section(section)
            section.fetch(:repeat).times do |repeat_index|
              yielder << {
                name: repeated_section_name(name, repeat_index),
                bars: section.fetch(:bars),
                tracks: section.fetch(:tracks),
                start_bar: cursor_bar,
                start_time: cursor_time,
                tempo: section.fetch(:tempo),
                beats_per_bar: section.fetch(:beats_per_bar),
                markers: section.fetch(:markers)
              }
              cursor_bar += section.fetch(:bars)
              cursor_time += section.fetch(:bars) * section_engine.send(:bar_duration_time)
            end
          end
        end
      end

      def normalize_arrangement_section(section, track_map)
        raise SequencerError, "section must be a Hash" unless section.is_a?(Hash)

        bars = section[:bars]
        unless bars.is_a?(Integer) && bars.between?(1, MAX_BARS)
          raise SequencerError, "section bars must be an Integer in 1..#{MAX_BARS}"
        end
        repeat = section.fetch(:repeat, 1)
        unless repeat.is_a?(Integer) && repeat.between?(1, MAX_SECTION_REPEAT)
          raise SequencerError, "section repeat must be an Integer in 1..#{MAX_SECTION_REPEAT}"
        end

        name = normalize_section_name(section[:name]) if section.key?(:name)
        track_names = normalize_section_track_names(section[:tracks])
        unknown = track_names - track_map.keys
        section_label = name || :unnamed
        raise SequencerError, "unknown tracks in section #{section_label}: #{unknown.join(', ')}" unless unknown.empty?

        {
          name: name,
          bars: bars,
          repeat: repeat,
          tracks: track_names,
          tempo: normalize_section_tempo(section[:tempo] || @tempo),
          beats_per_bar: validate_beats_per_bar!(section[:beats_per_bar] || @beats_per_bar),
          markers: normalize_section_markers(section.fetch(:markers, []))
        }
      end

      def normalize_section_name(name)
        value = name.to_sym
        raise SequencerError, "section name must not be empty" if value.to_s.empty?

        value
      rescue NoMethodError
        raise SequencerError, "section name must be Symbol/String"
      end

      def normalize_section_track_names(tracks)
        Array(tracks).map do |track_name|
          track_name.to_sym
        rescue NoMethodError
          raise SequencerError, "section tracks must be Symbols/Strings"
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
        work_format = @format.with(sample_format: :float, bit_depth: 32)
        samples = []
        sections.each do |section|
          section_engine = engine_for_section(section)
          section[:tracks].each do |track_name|
            audio = section_engine.send(
              :render_track_audio,
              track_map.fetch(track_name),
              bars: section[:bars],
              start_bar: 0,
              start_time: 0.0
            )
            next unless audio

            source = audio.buffer.convert(work_format)
            offset = (section[:start_time] * @format.sample_rate).round * work_format.channels
            required_length = offset + source.samples.length
            samples.concat(Array.new(required_length - samples.length, 0.0)) if required_length > samples.length
            source.samples.each_with_index { |sample, index| samples[offset + index] += sample }
          end
        end
        return [] if samples.empty?

        [Wavify::Audio.new(Wavify::Core::SampleBuffer.new(samples, work_format))]
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
        release_frames = (release_seconds * track_format.sample_rate).ceil
        total_end_frame = note_events.map do |event|
          event.fetch(:start_frame) + event.fetch(:duration_frames) + release_frames
        end.max || 0
        work_format = track_format.with(sample_format: :float, bit_depth: 32)
        mixed = Array.new(total_end_frame * work_format.channels, 0.0)

        note_events.each do |event|
          frequencies = event[:midi_notes].map { |midi| midi_to_frequency(midi) }
          render_oscillator_voices_into!(
            mixed,
            frequencies: frequencies,
            start_frame: event.fetch(:start_frame),
            duration: event.fetch(:duration),
            track: track,
            format: work_format
          )
        end

        rendered = Wavify::Audio.new(Wavify::Core::SampleBuffer.new(mixed, work_format))
        rendered = rendered.gain(track.gain_db) if track.gain_db != 0.0
        if track.pan_position != 0.0
          rendered = rendered.channels == 1 ? rendered.pan(track.pan_position) : rendered.balance(track.pan_position)
        end
        rendered = apply_track_effects(rendered, track.effects) if track.effects?
        rendered.convert(@format.with(sample_format: :float, bit_depth: 32))
      end

      def render_oscillator_voices_into!(samples, frequencies:, start_frame:, duration:, track:, format:)
        rendered_duration = duration.to_f + (track.envelope&.release || 0.0)
        frame_count = (rendered_duration * format.sample_rate).round
        if rendered_duration > Wavify::DSP::Oscillator::MAX_DURATION_SECONDS ||
           frame_count > Wavify::DSP::Oscillator::MAX_GENERATE_FRAMES
          raise SequencerError, "one sequencer note exceeds the oscillator frame limit"
        end

        mono_format = format.with(channels: 1)
        voice_gain = 1.0 / frequencies.length
        channels = format.channels
        frequencies.each do |frequency|
          voice = Wavify::DSP::Oscillator.new(
            frequency: frequency,
            waveform: track.waveform,
            **track.synth_options
          ).generate(rendered_duration, format: mono_format)
          voice.samples.each_with_index do |sample, frame_index|
            target_frame = start_frame + frame_index
            break if target_frame >= samples.length / channels

            value = sample * voice_gain
            if track.envelope
              time = frame_index.to_f / format.sample_rate
              value *= track.envelope.gain_at(time, note_on_duration: duration)
            end
            base_index = target_frame * channels
            channels.times { |channel| samples[base_index + channel] += value }
          end
        end
      end

      def master_audio(rendered_audios)
        work_format = @format.with(sample_format: :float, bit_depth: 32)
        mixed = Wavify::Audio.mix(*rendered_audios, strategy: :none, format: work_format)
        return Wavify::Audio.new(mixed.buffer.convert(@format)) if mixed.peak_amplitude <= 1.0

        limiter = Wavify::DSP::Effects::Limiter.new(ceiling: MASTER_CEILING_DB, attack: 0.0)
        limited = limiter.apply(mixed.buffer)
        Wavify::Audio.new(limited.convert(@format))
      end

      def schedule_pattern_events(track, bars:, start_bar:, start_time:)
        resolution = track.pattern.resolution

        (0...bars).flat_map do |bar_offset|
          track.pattern.filter(&:trigger?).flat_map do |step|
            absolute_bar = start_bar + bar_offset
            event_start_time = bar_start_time(absolute_bar, bar_offset, start_time) + step_start_time(step.index, resolution)
            duration = step_duration_time_at(step.index, resolution)
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
            event_start_time = bar_start_time(absolute_bar, bar_offset, start_time) + step_start_time(event.index, resolution)
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
          return (bar_duration_time / event.duration_denominator) * Rational(event.duration_multiplier.to_s)
        end

        step_duration_time_at(event.index, resolution)
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
            start_time: bar_start_time(absolute_bar, bar_offset, start_time),
            duration: bar_duration_time,
            midi_notes: chord.fetch(:midi_notes),
            chord: chord.fetch(:token)
          }
        end
      end

      def midi_to_frequency(midi_note)
        440.0 * (2.0**((midi_note - 69) / 12.0))
      end

      def apply_track_effects(audio, effects)
        audio.apply(Wavify::DSP::Effects::EffectChain.new(effects))
      end

      def validate_tempo!(tempo)
        unless tempo.is_a?(Numeric) && tempo.respond_to?(:finite?) && tempo.finite? && tempo.positive?
          raise SequencerError, "tempo must be a positive finite Numeric"
        end

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

      def seconds_per_beat_rational
        Rational(60, 1) / Rational(@tempo.to_s)
      end

      def bar_duration_time
        seconds_per_beat_rational * @beats_per_bar
      end

      def step_duration_time(resolution)
        raise SequencerError, "resolution must be a positive Integer" unless resolution.is_a?(Integer) && resolution.positive?

        bar_duration_time / resolution
      end

      def step_start_time(index, resolution)
        base_duration = step_duration_time(resolution)
        return index * base_duration if straight_timing?(resolution)

        pair_duration = base_duration * 2
        ((index / 2) * pair_duration) + (index.even? ? 0 : pair_duration * Rational(@swing.to_s))
      end

      def step_duration_time_at(index, resolution)
        base_duration = step_duration_time(resolution)
        return base_duration if straight_timing?(resolution)

        pair_duration = base_duration * 2
        pair_duration * (index.even? ? Rational(@swing.to_s) : (1 - Rational(@swing.to_s)))
      end

      def bar_start_time(absolute_bar, bar_offset, start_time)
        return (Rational(start_time.to_s) + (bar_offset * bar_duration_time)) if start_time

        absolute_bar * bar_duration_time
      end

      def engine_for_section(section)
        tempo = section[:tempo] || @tempo
        beats_per_bar = section[:beats_per_bar] || @beats_per_bar
        return self if tempo == @tempo && beats_per_bar == @beats_per_bar

        @section_engine_cache[[tempo, beats_per_bar]] ||= self.class.new(
          tempo: tempo,
          format: @format,
          beats_per_bar: beats_per_bar,
          swing: @swing
        )
      end

      def marker_events_for_section(section)
        section.fetch(:markers, []).map do |marker|
          decorate_event_timing({
            kind: :marker,
            track: :arrangement,
            bar: section.fetch(:start_bar),
            step_index: 0,
            start_time: section.fetch(:start_time),
            duration: 0.0,
            marker: marker,
            section: section.fetch(:name)
          })
        end
      end

      def decorate_event_timing(event)
        start_time = event.fetch(:start_time)
        duration = event.fetch(:duration)
        event.merge(
          start_time: start_time.to_f,
          duration: duration.to_f,
          start_frame: (start_time * @format.sample_rate).round,
          duration_frames: (duration * @format.sample_rate).round
        )
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
