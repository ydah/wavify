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

    it "returns silence when only pattern tracks are provided" do
      drums = Wavify::Sequencer::Track.new(:drums, pattern: "x---x---")

      audio = engine.render(tracks: [drums], default_bars: 1)

      expect(audio.sample_frame_count).to eq(0)
    end
  end
end
