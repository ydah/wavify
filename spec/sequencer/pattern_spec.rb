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

    it "parses explicit trigger velocities" do
      pattern = described_class.new("x0.25-.X0.9")

      expect(pattern.length).to eq(4)
      expect(pattern[0].velocity).to eq(0.25)
      expect(pattern[3]).to be_accent
      expect(pattern[3].velocity).to eq(0.9)
    end

    it "parses probability and ratchet modifiers" do
      pattern = described_class.new("x?50:3-X:2")

      expect(pattern.length).to eq(3)
      expect(pattern[0].probability).to eq(0.5)
      expect(pattern[0].ratchet).to eq(3)
      expect(pattern[2]).to be_accent
      expect(pattern[2].probability).to eq(1.0)
      expect(pattern[2].ratchet).to eq(2)
    end

    it "freezes notation and parsed steps" do
      notation = +"x---"
      pattern = described_class.new(notation)
      notation.replace("----")

      expect(pattern.notation).to eq("x---")
      expect(pattern).to be_frozen
      expect(pattern.steps).to all(be_frozen)
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

    it "rejects velocities outside the normalized range" do
      expect do
        described_class.new("x1.2---")
      end.to raise_error(Wavify::InvalidPatternError, /velocity/)
    end

    it "rejects invalid probability and ratchet modifiers" do
      expect do
        described_class.new("x?101")
      end.to raise_error(Wavify::InvalidPatternError, /probability/)

      expect do
        described_class.new("x:0")
      end.to raise_error(Wavify::InvalidPatternError, /ratchet/)
    end

    it "rejects duplicate modifiers and excessive resource values" do
      expect { described_class.new("x?50?20") }.to raise_error(Wavify::InvalidPatternError, /duplicate/)
      expect { described_class.new("x:2:4") }.to raise_error(Wavify::InvalidPatternError, /duplicate/)
      expect { described_class.new("x:65") }.to raise_error(Wavify::InvalidPatternError, /between 1 and 64/)
      expect { described_class.new("x---", resolution: 2) }.to raise_error(Wavify::InvalidPatternError, /steps.*resolution/)
      expect { described_class.new("x", resolution: 4_097) }.to raise_error(Wavify::InvalidPatternError, /4096/)
    end
  end
end
