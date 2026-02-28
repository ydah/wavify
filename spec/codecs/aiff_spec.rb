# frozen_string_literal: true

require "tempfile"

RSpec.describe Wavify::Codecs::Aiff do
  describe ".can_read?" do
    it "detects aiff extension" do
      expect(described_class.can_read?("demo.aiff")).to be(true)
    end
  end

  describe "roundtrip pcm" do
    it "roundtrips 16-bit stereo" do
      format = Wavify::Core::Format.new(channels: 2, sample_rate: 44_100, bit_depth: 16, sample_format: :pcm)
      buffer = Wavify::Core::SampleBuffer.new([1000, -1000, 20_000, -20_000], format)

      Tempfile.create(["wavify", ".aiff"]) do |file|
        described_class.write(file.path, buffer)
        decoded = described_class.read(file.path)

        expect(decoded.format).to eq(format)
        expect(decoded.samples).to eq(buffer.samples)
      end
    end

    it "roundtrips 24-bit mono" do
      format = Wavify::Core::Format.new(channels: 1, sample_rate: 48_000, bit_depth: 24, sample_format: :pcm)
      buffer = Wavify::Core::SampleBuffer.new([0, 100_000, -100_000, 500_000], format)

      Tempfile.create(["wavify", ".aif"]) do |file|
        described_class.write(file.path, buffer)
        decoded = described_class.read(file.path)

        expect(decoded.format).to eq(format)
        expect(decoded.samples).to eq(buffer.samples)
      end
    end
  end

  describe ".metadata" do
    it "returns format and duration" do
      format = Wavify::Core::Format.new(channels: 1, sample_rate: 44_100, bit_depth: 8, sample_format: :pcm)
      buffer = Wavify::Core::SampleBuffer.new([0] * 44_100, format)

      Tempfile.create(["wavify", ".aiff"]) do |file|
        described_class.write(file.path, buffer)
        metadata = described_class.metadata(file.path)

        expect(metadata[:format]).to eq(format)
        expect(metadata[:sample_frame_count]).to eq(44_100)
        expect(metadata[:duration].total_seconds).to eq(1.0)
      end
    end
  end

  describe ".stream_read" do
    it "yields chunked sample buffers" do
      format = Wavify::Core::Format.new(channels: 1, sample_rate: 44_100, bit_depth: 16, sample_format: :pcm)
      buffer = Wavify::Core::SampleBuffer.new([1, 2, 3, 4, 5, 6], format)

      Tempfile.create(["wavify", ".aiff"]) do |file|
        described_class.write(file.path, buffer)
        chunks = []
        described_class.stream_read(file.path, chunk_size: 2) { |chunk| chunks << chunk }

        expect(chunks.map(&:sample_frame_count)).to eq([2, 2, 2])
        expect(chunks.flat_map(&:samples)).to eq(buffer.samples)
      end
    end
  end

  describe "error handling" do
    it "raises on invalid header" do
      Tempfile.create(["wavify", ".aiff"]) do |file|
        file.write("NOTAIFF")
        file.flush

        expect do
          described_class.read(file.path)
        end.to raise_error(Wavify::InvalidFormatError)
      end
    end

    it "raises on AIFC form" do
      Tempfile.create(["wavify", ".aiff"]) do |file|
        file.binmode
        file.write("FORM")
        file.write([4].pack("N"))
        file.write("AIFC")
        file.flush

        expect do
          described_class.read(file.path)
        end.to raise_error(Wavify::UnsupportedFormatError)
      end
    end
  end
end
