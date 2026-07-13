# frozen_string_literal: true

RSpec.describe Wavify::Sequencer::Engine do
  let(:format) { Wavify::Core::Format.new(channels: 2, sample_rate: 44_100, bit_depth: 32, sample_format: :float) }
  let(:engine) { described_class.new(tempo: 120, format: format) }

  describe "time calculations" do
    it "calculates beat and bar durations" do
      expect(engine.seconds_per_beat).to be_within(0.0001).of(0.5)
      expect(engine.bar_duration_seconds).to be_within(0.0001).of(2.0)
      expect(engine.step_duration_seconds(16)).to be_within(0.0001).of(0.125)
    end

    it "delays off-beat steps when swing is enabled" do
      swung = described_class.new(tempo: 120, format: format, swing: 0.6)

      expect(swung.step_start_seconds(1, 4)).to be_within(0.0001).of(0.6)
      expect(swung.step_duration_at(0, 4)).to be_within(0.0001).of(0.6)
      expect(swung.step_duration_at(1, 4)).to be_within(0.0001).of(0.4)
    end
  end

  describe "#timeline_for_track" do
    it "schedules trigger events for pattern tracks" do
      track = Wavify::Sequencer::Track.new(:drums, pattern: "x---X---")
      events = engine.timeline_for_track(track, bars: 2)

      expect(events.length).to eq(4)
      expect(events.first[:kind]).to eq(:trigger)
      expect(events.first[:start_time]).to be_within(0.0001).of(0.0)
      expect(events[1][:velocity]).to eq(1.0)
      expect(events[2][:bar]).to eq(1)
      expect(events[2][:start_time]).to be_within(0.0001).of(2.0)
    end

    it "carries explicit pattern velocities into trigger events" do
      track = Wavify::Sequencer::Track.new(:drums, pattern: "x0.25---X0.9---")
      events = engine.timeline_for_track(track, bars: 1)

      expect(events.map { |event| event[:velocity] }).to eq([0.25, 0.9])
    end

    it "expands ratcheted trigger events and carries probability metadata" do
      track = Wavify::Sequencer::Track.new(:drums, pattern: "x?50:3---")
      events = engine.timeline_for_track(track, bars: 1)

      expect(events.length).to eq(3)
      expect(events.map { |event| event[:ratchet_index] }).to eq([0, 1, 2])
      expect(events.map { |event| event[:ratchet_count] }).to eq([3, 3, 3])
      expect(events.map { |event| event[:probability] }).to eq([0.5, 0.5, 0.5])
      expect(events[1][:start_time]).to be_within(0.0001).of(events[0][:duration])
    end

    it "schedules note and chord events" do
      track = Wavify::Sequencer::Track.new(
        :lead,
        note_sequence: "C4 . E4 G4",
        chord_progression: %w[Cm7 G7]
      )

      events = engine.timeline_for_track(track, bars: 2)
      kinds = events.map { |event| event[:kind] }

      expect(kinds.count(:note)).to eq(6)
      expect(kinds.count(:chord)).to eq(2)
      expect(events.any? { |event| event[:kind] == :chord && event[:chord] == "G7" }).to be(true)
    end

    it "uses note duration suffixes and ties adjacent equal notes" do
      track = Wavify::Sequencer::Track.new(:lead, note_sequence: "C4/8 D4~ D4 E4", note_resolution: 8)
      events = engine.timeline_for_track(track, bars: 1).select { |event| event[:kind] == :note }

      expect(events.length).to eq(3)
      expect(events[0][:duration]).to be_within(0.0001).of(engine.bar_duration_seconds / 8.0)
      expect(events[1][:midi_notes]).to eq([62])
      expect(events[1][:duration]).to be_within(0.0001).of(engine.step_duration_at(1, 8) + engine.step_duration_at(2, 8))
      expect(events[2][:midi_notes]).to eq([64])
    end

    it "uses dotted and triplet note duration suffixes" do
      track = Wavify::Sequencer::Track.new(:lead, note_sequence: "C4/8. D4/8t", note_resolution: 8)
      events = engine.timeline_for_track(track, bars: 1).select { |event| event[:kind] == :note }

      expect(events[0][:duration]).to be_within(0.0001).of((engine.bar_duration_seconds / 8.0) * 1.5)
      expect(events[1][:duration]).to be_within(0.0001).of((engine.bar_duration_seconds / 8.0) * (2.0 / 3.0))
    end

    it "quantizes note events through track key and scale settings" do
      track = Wavify::Sequencer::Track.new(:lead, note_sequence: "C#4 D#4", key: :c, scale: :minor)
      events = engine.timeline_for_track(track, bars: 1).select { |event| event[:kind] == :note }

      expect(events.map { |event| event[:midi_notes].first }).to eq([60, 63])
    end
  end

  describe "#build_timeline" do
    it "builds arranged timelines with section offsets" do
      lead = Wavify::Sequencer::Track.new(:lead, note_sequence: "C4 D4 E4 F4")
      drums = Wavify::Sequencer::Track.new(:drums, pattern: "x---x---")

      timeline = engine.build_timeline(
        tracks: [lead, drums],
        arrangement: [
          { name: :intro, bars: 1, tracks: [:lead] },
          { name: :verse, bars: 2, tracks: %i[drums lead] }
        ]
      )

      expect(timeline.first[:start_time]).to be >= 0.0
      expect(timeline.any? { |event| event[:track] == :drums && event[:bar] == 1 }).to be(true)
      expect(timeline.any? { |event| event[:track] == :lead && event[:bar] == 2 }).to be(true)
    end

    it "expands repeated arrangement sections" do
      lead = Wavify::Sequencer::Track.new(:lead, note_sequence: "C4")

      timeline = engine.build_timeline(
        tracks: [lead],
        arrangement: [
          { name: :riff, bars: 1, tracks: [:lead], repeat: 3 }
        ]
      )

      expect(timeline.map { |event| event[:bar] }.uniq).to eq([0, 1, 2])
    end

    it "supports section tempo, meter, and marker metadata" do
      lead = Wavify::Sequencer::Track.new(:lead, note_sequence: "C4")

      timeline = engine.build_timeline(
        tracks: [lead],
        arrangement: [
          { name: :intro, bars: 1, tracks: [:lead], markers: [:start] },
          { name: :bridge, bars: 1, tracks: [:lead], tempo: 60, beats_per_bar: 3, markers: [:bridge] }
        ]
      )

      markers = timeline.select { |event| event[:kind] == :marker }
      bridge_note = timeline.find { |event| event[:kind] == :note && event[:bar] == 1 }
      expect(markers.map { |event| event[:marker] }).to eq(%i[start bridge])
      expect(bridge_note[:start_time]).to be_within(0.0001).of(2.0)
      expect(bridge_note[:duration]).to be_within(0.0001).of(3.0 / 8.0)
    end

    it "rejects duplicate track names" do
      first = Wavify::Sequencer::Track.new(:lead, note_sequence: "C4")
      second = Wavify::Sequencer::Track.new(:lead, note_sequence: "E4")

      expect do
        engine.build_timeline(tracks: [first, second])
      end.to raise_error(Wavify::SequencerError, /duplicate track name/)
    end
  end

  describe "#render" do
    it "renders note tracks to mixed audio" do
      lead = Wavify::Sequencer::Track.new(
        :lead,
        note_sequence: "C4 E4 G4 C5",
        waveform: :sine,
        gain_db: -6.0,
        pan_position: -0.2
      )
      pad = Wavify::Sequencer::Track.new(
        :pad,
        chord_progression: ["Cm7"],
        waveform: :triangle,
        gain_db: -12.0,
        pan_position: 0.2,
        envelope: Wavify::DSP::Envelope.new(attack: 0.01, decay: 0.05, sustain: 0.7, release: 0.05)
      )

      audio = engine.render(tracks: [lead, pad], default_bars: 1)

      expect(audio).to be_a(Wavify::Audio)
      expect(audio.format).to eq(format)
      expect(audio.sample_frame_count).to be > 0
      expect(audio.peak_amplitude).to be > 0.0
    end

    it "renders envelope release samples beyond note-on duration" do
      envelope = Wavify::DSP::Envelope.new(attack: 0.0, decay: 0.0, sustain: 1.0, release: 0.1)
      lead = Wavify::Sequencer::Track.new(:lead, note_sequence: "C4", note_resolution: 4, envelope: envelope)

      audio = engine.render(tracks: [lead], default_bars: 1)
      note_duration = engine.step_duration_at(0, 4)

      expect(audio.duration.total_seconds).to be_within(1.0 / format.sample_rate).of(note_duration + 0.1)
      release_start = (note_duration * format.sample_rate).round * format.channels
      expect(audio.buffer.samples.drop(release_start).any? { |sample| sample.abs > 0.0 }).to eq(true)
    end

    it "mixes chord voices with headroom" do
      chord = Wavify::Sequencer::Track.new(:pad, chord_progression: ["Cmaj7"], waveform: :sine)

      audio = engine.render(tracks: [chord], default_bars: 1)

      expect(audio.peak_amplitude).to be <= 1.0
      expect(audio.clipped?).to eq(false)
    end

    it "returns silence when only pattern tracks are provided" do
      drums = Wavify::Sequencer::Track.new(:drums, pattern: "x---x---")

      audio = engine.render(tracks: [drums], default_bars: 1)

      expect(audio.sample_frame_count).to eq(0)
    end
  end
end
