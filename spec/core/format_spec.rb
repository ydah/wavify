# frozen_string_literal: true

RSpec.describe Wavify::Core::Format do
  describe "presets" do
    it "defines CD quality" do
      format = described_class::CD_QUALITY
      expect(format.channels).to eq(2)
      expect(format.sample_rate).to eq(44_100)
      expect(format.bit_depth).to eq(16)
      expect(format.sample_format).to eq(:pcm)
    end

    it "defines DVD quality" do
      format = described_class::DVD_QUALITY
      expect(format.channels).to eq(2)
      expect(format.sample_rate).to eq(96_000)
      expect(format.bit_depth).to eq(24)
      expect(format.sample_format).to eq(:pcm)
    end

    it "defines voice preset" do
      format = described_class::VOICE
      expect(format.channels).to eq(1)
      expect(format.sample_rate).to eq(16_000)
      expect(format.bit_depth).to eq(16)
      expect(format.sample_format).to eq(:pcm)
    end
  end

  describe "#with" do
    it "returns a new derived format" do
      original = described_class::CD_QUALITY
      updated = original.with(sample_rate: 48_000, channels: 1)

      expect(updated).not_to equal(original)
      expect(updated.sample_rate).to eq(48_000)
      expect(updated.channels).to eq(1)
      expect(updated.bit_depth).to eq(16)
    end
  end

  describe "validation" do
    it "raises on invalid channels" do
      expect do
        described_class.new(channels: 0, sample_rate: 44_100, bit_depth: 16)
      end.to raise_error(Wavify::InvalidFormatError)
    end

    it "raises on invalid sample_rate" do
      expect do
        described_class.new(channels: 2, sample_rate: 1000, bit_depth: 16)
      end.to raise_error(Wavify::InvalidFormatError)
    end

    it "raises on invalid bit_depth for pcm" do
      expect do
        described_class.new(channels: 2, sample_rate: 44_100, bit_depth: 12, sample_format: :pcm)
      end.to raise_error(Wavify::InvalidFormatError)
    end

    it "raises on unsupported sample format" do
      expect do
        described_class.new(channels: 2, sample_rate: 44_100, bit_depth: 16, sample_format: :mulaw)
      end.to raise_error(Wavify::UnsupportedFormatError)
    end
  end

  describe "derived values" do
    it "computes byte_rate and block_align" do
      format = described_class::CD_QUALITY

      expect(format.block_align).to eq(4)
      expect(format.byte_rate).to eq(176_400)
    end
  end

  describe "equality" do
    it "compares by audio parameters" do
      left = described_class.new(channels: 2, sample_rate: 44_100, bit_depth: 16, sample_format: :pcm)
      right = described_class.new(channels: 2, sample_rate: 44_100, bit_depth: 16, sample_format: :pcm)
      different = described_class.new(channels: 1, sample_rate: 44_100, bit_depth: 16, sample_format: :pcm)

      expect(left).to eq(right)
      expect(left.hash).to eq(right.hash)
      expect(left).not_to eq(different)
    end
  end
end
