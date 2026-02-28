# frozen_string_literal: true

RSpec.describe Wavify::Sequencer::Pattern do
  describe "parsing" do
    it "parses triggers, rests, and accents" do
      pattern = described_class.new("X---x.-.")

      expect(pattern.length).to eq(8)
      expect(pattern.trigger_indices).to eq([0, 4])
      expect(pattern.accented_indices).to eq([0])
      expect(pattern[0].velocity).to eq(1.0)
      expect(pattern[4].velocity).to eq(0.8)
      expect(pattern[5]).to be_rest
      expect(pattern[6]).to be_rest
    end

    it "ignores whitespace and bar separators" do
      pattern = described_class.new("x--- | x---")

      expect(pattern.length).to eq(8)
      expect(pattern.trigger_indices).to eq([0, 4])
    end
  end

  describe "validation" do
    it "rejects invalid symbols" do
      expect do
        described_class.new("x-o-")
      end.to raise_error(Wavify::InvalidPatternError)
    end

    it "rejects empty notation" do
      expect do
        described_class.new("   ")
      end.to raise_error(Wavify::InvalidPatternError)
    end
  end
end
