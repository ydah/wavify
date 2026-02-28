# frozen_string_literal: true

require "tempfile"
require "stringio"

RSpec.describe Wavify::Codecs::Raw do
  let(:format) { Wavify::Core::Format.new(channels: 2, sample_rate: 44_100, bit_depth: 16, sample_format: :pcm) }

  describe ".can_read?" do
    it "detects IO objects and raw extensions" do
      expect(described_class.can_read?(StringIO.new)).to be(true)
      expect(described_class.can_read?("demo.raw")).to be(true)
      expect(described_class.can_read?("demo.pcm")).to be(true)
      expect(described_class.can_read?("demo.wav")).to be(false)
      expect(described_class.can_read?(123)).to be(false)
    end
  end

  describe ".write/.read" do
    it "roundtrips raw pcm with explicit format" do
      source = Wavify::Core::SampleBuffer.new([1000, -1000, 2000, -2000], format)

      Tempfile.create(["wavify", ".raw"]) do |file|
        described_class.write(file.path, source, format: format)
        decoded = described_class.read(file.path, format: format)

        expect(decoded.format).to eq(format)
        expect(decoded.samples).to eq(source.samples)
      end
    end

    it "requires format when reading" do
      Tempfile.create(["wavify", ".raw"]) do |file|
        file.write("\x00\x00".b)
        file.flush

        expect do
          described_class.read(file.path)
        end.to raise_error(Wavify::InvalidFormatError)
      end
    end

    it "roundtrips multiple raw sample encodings" do
      cases = [
        {
          format: Wavify::Core::Format.new(channels: 1, sample_rate: 44_100, bit_depth: 8, sample_format: :pcm),
          samples: [-128, -1, 0, 1, 127]
        },
        {
          format: Wavify::Core::Format.new(channels: 1, sample_rate: 44_100, bit_depth: 24, sample_format: :pcm),
          samples: [-8_388_608, -123_456, 0, 654_321, 8_388_607]
        },
        {
          format: Wavify::Core::Format.new(channels: 1, sample_rate: 44_100, bit_depth: 32, sample_format: :pcm),
          samples: [-2_000_000, 0, 2_000_000]
        },
        {
          format: Wavify::Core::Format.new(channels: 1, sample_rate: 44_100, bit_depth: 32, sample_format: :float),
          samples: [-1.2, -0.5, 0.0, 0.75, 1.3]
        },
        {
          format: Wavify::Core::Format.new(channels: 1, sample_rate: 44_100, bit_depth: 64, sample_format: :float),
          samples: [-0.25, 0.0, 0.25]
        }
      ]

      cases.each do |entry|
        io = StringIO.new(+"", "w+b")
        source = Wavify::Core::SampleBuffer.new(entry.fetch(:samples), entry.fetch(:format))

        described_class.write(io, source, format: entry.fetch(:format))
        io.rewind
        decoded = described_class.read(io, format: entry.fetch(:format))

        expect(decoded.format).to eq(entry.fetch(:format))
        if entry.fetch(:format).sample_format == :float
          decoded.samples.zip(source.samples).each do |actual, expected|
            expect(actual).to be_within(1e-6).of(expected.clamp(-1.0, 1.0))
          end
        else
          expect(decoded.samples).to eq(source.samples)
        end
      end
    end
  end

  describe ".stream_read" do
    it "yields chunked sample buffers" do
      source = Wavify::Core::SampleBuffer.new([1, 2, 3, 4, 5, 6, 7, 8], format)

      Tempfile.create(["wavify", ".raw"]) do |file|
        described_class.write(file.path, source, format: format)

        chunks = []
        described_class.stream_read(file.path, format: format, chunk_size: 2) { |chunk| chunks << chunk }

        expect(chunks.map(&:sample_frame_count)).to eq([2, 2])
        expect(chunks.flat_map(&:samples)).to eq(source.samples)
      end
    end

    it "returns an enumerator when no block is given" do
      enum = described_class.stream_read("demo.raw", format: format, chunk_size: 4)
      expect(enum).to be_an(Enumerator)
    end
  end

  describe ".stream_write" do
    it "writes chunks and returns the io_or_path" do
      io = StringIO.new(+"", "w+b")
      float_format = format.with(sample_format: :float, bit_depth: 32)
      chunk = Wavify::Core::SampleBuffer.new([0.25, -0.25, 0.5, -0.5], float_format)

      result = described_class.stream_write(io, format: format) do |writer|
        writer.call(chunk)
      end

      expect(result).to eq(io)
      io.rewind
      decoded = described_class.read(io, format: format)
      expect(decoded.sample_frame_count).to eq(2)
      expect(decoded.samples).to eq([8_192, -8_192, 16_384, -16_384])
    end

    it "returns an enumerator when no block is given" do
      enum = described_class.stream_write("demo.raw", format: format)
      expect(enum).to be_an(Enumerator)
    end

    it "raises when stream chunk is not a sample buffer" do
      io = StringIO.new(+"", "w+b")

      expect do
        described_class.stream_write(io, format: format) do |writer|
          writer.call(:invalid)
        end
      end.to raise_error(Wavify::InvalidParameterError, /stream chunk/)
    end
  end

  describe ".metadata" do
    it "works with read-only io objects that do not expose #size" do
      raw_bytes = [1, 2, 3, 4].pack("s<*")
      io_class = Class.new do
        def initialize(bytes)
          @bytes = bytes
          @read = false
        end

        def read(_size = nil)
          return nil if @read

          @read = true
          @bytes
        end
      end

      metadata = described_class.metadata(io_class.new(raw_bytes), format: format.with(channels: 1))
      expect(metadata[:sample_frame_count]).to eq(4)
      expect(metadata[:duration].total_seconds).to be_within(1e-9).of(4.0 / 44_100)
    end

    it "raises a friendly error when input file is missing" do
      expect do
        described_class.metadata("__missing__/demo.raw", format: format)
      end.to raise_error(Wavify::InvalidFormatError, /input file not found/)
    end
  end
end
