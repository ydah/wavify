# frozen_string_literal: true

RSpec.describe Wavify::Core::Duration do
  describe ".from_samples" do
    it "builds duration from sample frames" do
      duration = described_class.from_samples(44_100, 44_100)
      expect(duration.total_seconds).to eq(1.0)
    end

    it "raises on invalid sample count" do
      expect do
        described_class.from_samples(-1, 44_100)
      end.to raise_error(Wavify::InvalidParameterError)
    end
  end

  describe "#to_s" do
    it "renders HH:MM:SS.mmm format" do
      duration = described_class.new(3_726.045)
      expect(duration.to_s).to eq("01:02:06.045")
    end
  end

  describe "comparison and arithmetic" do
    it "supports comparable behavior" do
      short = described_class.new(1.5)
      long = described_class.new(2.0)

      expect(short).to be < long
      expect(long).to be > short
    end

    it "supports addition and subtraction" do
      first = described_class.new(2.25)
      second = described_class.new(1.75)

      expect((first + second).total_seconds).to eq(4.0)
      expect((first - second).total_seconds).to eq(0.5)
    end

    it "rejects negative subtraction results" do
      first = described_class.new(1.0)
      second = described_class.new(2.0)

      expect do
        first - second
      end.to raise_error(Wavify::InvalidParameterError)
    end
  end
end
