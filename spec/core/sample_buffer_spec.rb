# frozen_string_literal: true

RSpec.describe Wavify::Core::SampleBuffer do
  let(:pcm16_stereo) { Wavify::Core::Format.new(channels: 2, sample_rate: 44_100, bit_depth: 16, sample_format: :pcm) }
  let(:float_stereo) { Wavify::Core::Format.new(channels: 2, sample_rate: 44_100, bit_depth: 32, sample_format: :float) }

  describe "basic behavior" do
    it "exposes length and frame count" do
      buffer = described_class.new([1000, -1000, 2000, -2000], pcm16_stereo)

      expect(buffer.length).to eq(4)
      expect(buffer.sample_frame_count).to eq(2)
    end

    it "supports enumerable traversal" do
      buffer = described_class.new([1, 2, 3, 4], pcm16_stereo)

      expect(buffer.map { |sample| sample * 2 }).to eq([2, 4, 6, 8])
    end

    it "reverses frame order while preserving channel order" do
      buffer = described_class.new([1, 2, 3, 4, 5, 6], Wavify::Core::Format.new(channels: 2, sample_rate: 48_000, bit_depth: 16))
      reversed = buffer.reverse

      expect(reversed.samples).to eq([5, 6, 3, 4, 1, 2])
    end

    it "slices by frame" do
      buffer = described_class.new([1, 2, 3, 4, 5, 6], pcm16_stereo)
      sliced = buffer.slice(1, 2)

      expect(sliced.samples).to eq([3, 4, 5, 6])
      expect(sliced.sample_frame_count).to eq(2)
    end

    it "concats another buffer" do
      left = described_class.new([1, 2, 3, 4], pcm16_stereo)
      right = described_class.new([5, 6], Wavify::Core::Format.new(channels: 2, sample_rate: 44_100, bit_depth: 16))

      combined = left + right
      expect(combined.samples).to eq([1, 2, 3, 4, 5, 6])
    end
  end

  describe "#convert" do
    it "converts between pcm bit depths with limited quantization error" do
      source = described_class.new([12_345, -12_345, 20_000, -20_000], pcm16_stereo)
      pcm24 = pcm16_stereo.with(bit_depth: 24)

      round_trip = source.convert(pcm24).convert(pcm16_stereo)
      differences = source.samples.zip(round_trip.samples).map { |a, b| (a - b).abs }

      expect(differences.max).to be <= 1
    end

    it "upmixes mono to stereo" do
      mono = Wavify::Core::Format.new(channels: 1, sample_rate: 44_100, bit_depth: 32, sample_format: :float)
      source = described_class.new([0.2, -0.2], mono)

      stereo = source.convert(float_stereo)
      expect(stereo.samples).to eq([0.2, 0.2, -0.2, -0.2])
    end

    it "downmixes stereo to mono by averaging channels" do
      mono = Wavify::Core::Format.new(channels: 1, sample_rate: 44_100, bit_depth: 32, sample_format: :float)
      source = described_class.new([1.0, -1.0, 0.5, 0.5], float_stereo)

      converted = source.convert(mono)
      expect(converted.samples).to eq([0.0, 0.5])
    end

    it "downmixes multichannel source to stereo using speaker mapping" do
      surround = Wavify::Core::Format.new(channels: 3, sample_rate: 44_100, bit_depth: 32, sample_format: :float)
      source = described_class.new([1.0, 0.0, 1.0], surround)

      converted = source.convert(float_stereo)
      expect(converted.samples[0]).to eq(1.0)
      expect(converted.samples[1]).to be_within(0.0001).of(0.707)
    end
  end

  describe "validation" do
    it "rejects non-numeric samples" do
      expect do
        described_class.new([1, "x"], pcm16_stereo)
      end.to raise_error(Wavify::InvalidParameterError)
    end

    it "rejects invalid interleaving" do
      expect do
        described_class.new([1, 2, 3], pcm16_stereo)
      end.to raise_error(Wavify::InvalidParameterError)
    end
  end
end
