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

    it "writes at the current position and removes stale trailing bytes" do
      mono = format.with(channels: 1)
      io = StringIO.new(+"prefix-stale", "r+b")
      io.pos = 7

      described_class.write(io, Wavify::Core::SampleBuffer.new([100], mono), format: mono)

      expect(io.string).to eq("prefix-" + [100].pack("s<"))
      expect(io.pos).to eq(io.string.bytesize)
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

    it "rejects raw input that ends mid-frame" do
      io = StringIO.new("\x00\x00\x00")

      expect do
        described_class.read(io, format: format)
      end.to raise_error(Wavify::InvalidFormatError, /frame size/)
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

    it "supports big-endian signed PCM" do
      mono = format.with(channels: 1)
      source = Wavify::Core::SampleBuffer.new([-32_768, -1, 0, 1, 32_767], mono)
      io = StringIO.new(+"".b, "w+b")

      described_class.write(io, source, format: mono, endianness: :big, signed: true)

      expect(io.string).to eq(source.samples.pack("s>*"))
      io.rewind
      expect(described_class.read(io, format: mono, endianness: :big, signed: true)).to eq(source)
    end

    it "supports unsigned PCM words with the signed-domain midpoint" do
      mono = format.with(channels: 1)
      source = Wavify::Core::SampleBuffer.new([-32_768, 0, 32_767], mono)
      io = StringIO.new(+"".b, "w+b")

      described_class.write(io, source, format: mono, signed: false)

      expect(io.string).to eq([0, 32_768, 65_535].pack("S<*"))
      io.rewind
      expect(described_class.read(io, format: mono, signed: false)).to eq(source)
    end

    it "roundtrips big-endian unsigned 24-bit PCM" do
      mono = format.with(channels: 1, bit_depth: 24)
      source = Wavify::Core::SampleBuffer.new([-8_388_608, 0, 8_388_607], mono)
      io = StringIO.new(+"".b, "w+b")

      described_class.write(io, source, format: mono, endianness: :big, signed: false)

      expect(io.string).to eq("\x00\x00\x00\x80\x00\x00\xFF\xFF\xFF".b)
      io.rewind
      expect(described_class.read(io, format: mono, endianness: :big, signed: false)).to eq(source)
    end

    it "distinguishes normalized audio floats from unrestricted IEEE values" do
      float_format = format.with(channels: 1, bit_depth: 32, sample_format: :float)
      source = Wavify::Core::SampleBuffer.new([1.5, -2.0], float_format)
      ieee_io = StringIO.new(+"".b, "w+b")

      described_class.write(ieee_io, source, format: float_format, float_domain: :ieee)
      ieee_io.rewind
      decoded = described_class.read(ieee_io, format: float_format, float_domain: :ieee)
      expect(decoded.samples).to eq([1.5, -2.0])

      ieee_io.rewind
      expect do
        described_class.read(ieee_io, format: float_format, float_domain: :normalized)
      end.to raise_error(Wavify::InvalidFormatError, /normalized raw float/)

      normalized_io = StringIO.new(+"".b, "w+b")
      described_class.write(normalized_io, source, format: float_format, float_domain: :normalized)
      normalized_io.rewind
      expect(described_class.read(normalized_io, format: float_format).samples).to eq([1.0, -1.0])
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

    it "carries partial frames across short reads" do
      short_io = Class.new do
        def initialize(bytes)
          @io = StringIO.new(bytes)
        end

        def read(_size)
          @io.read(1)
        end
      end.new([1, 2, 3].pack("s<*"))
      format = Wavify::Core::Format.new(channels: 1, sample_rate: 8_000, bit_depth: 16, sample_format: :pcm)

      chunks = described_class.stream_read(short_io, format: format, chunk_size: 2).to_a

      expect(chunks.flat_map(&:samples)).to eq([1, 2, 3])
    end

    it "preserves encoding options across short reads" do
      short_io = Class.new do
        def initialize(bytes)
          @io = StringIO.new(bytes)
        end

        def read(_size)
          @io.read(1)
        end
      end.new([0, 32_768, 65_535].pack("S>*"))
      mono = format.with(channels: 1)

      chunks = described_class.stream_read(
        short_io,
        format: mono,
        chunk_size: 2,
        endianness: :big,
        signed: false
      ).to_a

      expect(chunks.flat_map(&:samples)).to eq([-32_768, 0, 32_767])
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
    it "measures seekable IO without consuming its current position" do
      raw_bytes = [1, 2, 3, 4].pack("s<*")
      io_class = Class.new do
        def initialize(bytes)
          @io = StringIO.new(bytes)
        end

        def pos = @io.pos
        def seek(...) = @io.seek(...)
        def read(...) = @io.read(...)
      end

      io = io_class.new(raw_bytes)
      metadata = described_class.metadata(io, format: format.with(channels: 1))
      expect(metadata[:sample_frame_count]).to eq(4)
      expect(metadata[:duration].total_seconds).to be_within(1e-9).of(4.0 / 44_100)
      expect(io.pos).to eq(0)
    end

    it "does not consume non-seekable IO to calculate metadata" do
      io_class = Class.new do
        attr_reader :read_count

        def initialize
          @read_count = 0
        end

        def read(*)
          @read_count += 1
          "\x00\x00"
        end
      end
      io = io_class.new

      expect do
        described_class.metadata(io, format: format.with(channels: 1))
      end.to raise_error(Wavify::InvalidParameterError, /size or seek/)
      expect(io.read_count).to eq(0)
    end

    it "rejects metadata sizes that end mid-frame" do
      io = StringIO.new("\x00\x00\x00")

      expect do
        described_class.metadata(io, format: format)
      end.to raise_error(Wavify::InvalidFormatError, /frame size/)
    end

    it "raises a friendly error when input file is missing" do
      expect do
        described_class.metadata("__missing__/demo.raw", format: format)
      end.to raise_error(Wavify::InvalidFormatError, /input file not found/)
    end
  end
end
