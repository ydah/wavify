# frozen_string_literal: true

RSpec.describe Wavify::Sequencer::Track do
  describe "construction" do
    it "coerces pattern and notes from strings" do
      track = described_class.new(
        :lead,
        pattern: "x---x---",
        note_sequence: "C4 D4 . G4",
        waveform: :triangle,
        gain_db: -3.0,
        pan_position: 0.2
      )

      expect(track.name).to eq(:lead)
      expect(track.pattern).to be_a(Wavify::Sequencer::Pattern)
      expect(track.note_sequence).to be_a(Wavify::Sequencer::NoteSequence)
      expect(track.waveform).to eq(:triangle)
      expect(track.gain_db).to eq(-3.0)
      expect(track.pan_position).to eq(0.2)
    end

    it "supports immutable builder helpers" do
      base = described_class.new(:bass)
      updated = base.with_pattern("x---").with_notes("C2 . G2 .").with_pan(-0.4)

      expect(base.pattern).to be_nil
      expect(updated.pattern).to be_a(Wavify::Sequencer::Pattern)
      expect(updated.note_sequence).to be_a(Wavify::Sequencer::NoteSequence)
      expect(updated.pan_position).to eq(-0.4)
    end
  end

  describe "chord parsing" do
    it "parses common chord names to midi note lists" do
      progression = described_class.parse_chords(%w[Cm7 Fmaj7 G7], default_octave: 3)

      expect(progression.map { |chord| chord[:token] }).to eq(%w[Cm7 Fmaj7 G7])
      expect(progression[0][:midi_notes]).to eq([48, 51, 55, 58])
      expect(progression[1][:midi_notes]).to eq([53, 57, 60, 64])
      expect(progression[2][:midi_notes]).to eq([55, 59, 62, 65])
    end

    it "rejects unsupported chord qualities" do
      expect do
        described_class.parse_chords(["C13"])
      end.to raise_error(Wavify::InvalidNoteError)
    end
  end
end
