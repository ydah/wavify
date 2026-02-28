# frozen_string_literal: true

RSpec.describe Wavify::Sequencer::NoteSequence do
  describe "parsing" do
    it "parses note names and rests" do
      sequence = described_class.new("C4 D#4 . G4")

      expect(sequence.length).to eq(4)
      expect(sequence.midi_notes).to eq([60, 63, nil, 67])
      expect(sequence[2]).to be_rest
    end

    it "parses midi note numbers" do
      sequence = described_class.new("60 62 64 . 67")

      expect(sequence.midi_notes).to eq([60, 62, 64, nil, 67])
    end

    it "uses default octave when octave is omitted" do
      sequence = described_class.new("C D E", default_octave: 3)

      expect(sequence.midi_notes).to eq([48, 50, 52])
    end

    it "supports flats" do
      sequence = described_class.new("Db4 Eb4 Bb3")

      expect(sequence.midi_notes).to eq([61, 63, 58])
    end
  end

  describe "validation" do
    it "rejects invalid note tokens" do
      expect do
        described_class.new("H2")
      end.to raise_error(Wavify::InvalidNoteError)
    end

    it "rejects midi notes out of range" do
      expect do
        described_class.new("130")
      end.to raise_error(Wavify::InvalidNoteError)
    end

    it "rejects empty notation" do
      expect do
        described_class.new("   ")
      end.to raise_error(Wavify::InvalidNoteError)
    end
  end
end
