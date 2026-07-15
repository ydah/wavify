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

    it "writes uncompressed AIFF-C with little-endian PCM when requested" do
      format = Wavify::Core::Format.new(channels: 1, sample_rate: 44_100, bit_depth: 16, sample_format: :pcm)
      buffer = Wavify::Core::SampleBuffer.new([100, -200, 300], format)

      Tempfile.create(["wavify", ".aifc"]) do |file|
        described_class.write(file.path, buffer, compression_type: "sowt")
        metadata = described_class.metadata(file.path)
        decoded = described_class.read(file.path)

        expect(metadata[:form_type]).to eq("AIFC")
        expect(metadata[:compression_type]).to eq("sowt")
        expect(metadata[:compression_name]).to eq("little-endian PCM")
        expect(decoded.format).to eq(format)
        expect(decoded.samples).to eq(buffer.samples)
      end
    end

    it "does not truncate caller-owned IO before writing" do
      format = Wavify::Core::Format.new(channels: 1, sample_rate: 8_000, bit_depth: 8, sample_format: :pcm)
      buffer = Wavify::Core::SampleBuffer.new([0], format)
      io = StringIO.new(+"existing bytes", "r+b")
      expect(io).not_to receive(:truncate)

      described_class.write(io, buffer)
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

    it "parses marker and instrument loop metadata" do
      format = Wavify::Core::Format.new(channels: 1, sample_rate: 44_100, bit_depth: 8, sample_format: :pcm)
      comm_chunk = described_class.send(:build_comm_chunk, format, 4)
      marker_name = "loop"
      marker_record = [1, 10, marker_name.bytesize].pack("n N C") + marker_name + "\x00"
      mark_chunk = [1].pack("n") + marker_record
      inst_chunk = [60, 0, 0, 127, 1, 127, 0].pack("C6s>") + [1, 1, 1, 0, 0, 0].pack("n6")
      ssnd_chunk = [0, 0].pack("N2") + [0, 1, 2, 3].pack("c*")
      bytes = build_aiff_bytes(
        ["COMM", comm_chunk],
        ["MARK", mark_chunk],
        ["INST", inst_chunk],
        ["SSND", ssnd_chunk]
      )

      Tempfile.create(["wavify-aiff-metadata", ".aiff"]) do |file|
        file.binmode
        file.write(bytes)
        file.flush

        metadata = described_class.metadata(file.path)
        expect(metadata[:markers]).to eq([{ identifier: 1, position: 10, name: "loop" }])
        expect(metadata[:instrument][:base_note]).to eq(60)
        expect(metadata[:instrument][:sustain_loop]).to eq(mode: 1, begin_marker: 1, end_marker: 1)
      end
    end

    it "reads uncompressed AIFF-C metadata and little-endian PCM samples" do
      format = Wavify::Core::Format.new(channels: 1, sample_rate: 44_100, bit_depth: 16, sample_format: :pcm)
      comm_chunk = described_class.send(:build_comm_chunk, format, 3) + "sowt" + pascal_string("little-endian PCM")
      ssnd_chunk = [0, 0].pack("N2") + [100, -200, 300].pack("s<*")
      bytes = build_aiff_bytes(
        ["COMM", comm_chunk],
        ["SSND", ssnd_chunk],
        form_type: "AIFC"
      )

      Tempfile.create(["wavify-aifc", ".aifc"]) do |file|
        file.binmode
        file.write(bytes)
        file.flush

        metadata = described_class.metadata(file.path)
        decoded = described_class.read(file.path)
        expect(metadata[:form_type]).to eq("AIFC")
        expect(metadata[:compression_type]).to eq("sowt")
        expect(metadata[:compression_name]).to eq("little-endian PCM")
        expect(decoded.format).to eq(format)
        expect(decoded.samples).to eq([100, -200, 300])
      end
    end

    it "maps non-byte-aligned sample sizes to their PCM container width" do
      cases = [
        { valid_bits: 12, container_bits: 16, samples: [0x1230, -0x1230], bytes: [0x1230, -0x1230].pack("s>*") },
        {
          valid_bits: 20,
          container_bits: 24,
          samples: [0x123450, -0x123450],
          bytes: described_class.send(:encode_pcm24_be, [0x123450, -0x123450])
        }
      ]

      cases.each do |entry|
        comm_chunk = [1, 2, entry.fetch(:valid_bits)].pack("n N n") + described_class.send(:encode_extended80, 44_100.0)
        ssnd_chunk = [0, 0].pack("N2") + entry.fetch(:bytes)
        io = StringIO.new(build_aiff_bytes(["COMM", comm_chunk], ["SSND", ssnd_chunk]))

        metadata = described_class.metadata(io)
        io.rewind
        decoded = described_class.read(io)

        expect(metadata[:format].bit_depth).to eq(entry.fetch(:container_bits))
        expect(metadata[:container_bit_depth]).to eq(entry.fetch(:container_bits))
        expect(metadata[:valid_bits_per_sample]).to eq(entry.fetch(:valid_bits))
        expect(decoded.samples).to eq(entry.fetch(:samples))
      end
    end

    it "reports rounding of non-integer 80-bit sample rates" do
      comm_chunk = [1, 1, 16].pack("n N n") + described_class.send(:encode_extended80, 44_100.5)
      ssnd_chunk = [0, 0].pack("N2") + [0].pack("s>")
      bytes = build_aiff_bytes(["COMM", comm_chunk], ["SSND", ssnd_chunk])
      warnings = StringIO.new

      metadata = described_class.metadata(StringIO.new(bytes))
      described_class.read(StringIO.new(bytes), warning_io: warnings)

      expect(metadata[:encoded_sample_rate]).to eq(44_100.5)
      expect(metadata[:format].sample_rate).to eq(44_101)
      expect(metadata[:warnings]).to include(/rounded to 44101 Hz/)
      expect(warnings.string).to include("AIFF warning:", "rounded to 44101 Hz")
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

    it "raises on unsupported compressed AIFC form" do
      Tempfile.create(["wavify", ".aiff"]) do |file|
        file.binmode
        format = Wavify::Core::Format.new(channels: 1, sample_rate: 44_100, bit_depth: 16, sample_format: :pcm)
        comm_chunk = described_class.send(:build_comm_chunk, format, 0) + "fl32" + pascal_string("float")
        file.write(build_aiff_bytes(["COMM", comm_chunk], ["SSND", [0, 0].pack("N2")], form_type: "AIFC"))
        file.flush

        expect do
          described_class.read(file.path)
        end.to raise_error(Wavify::UnsupportedFormatError)
      end
    end

    it "rejects a missing padding byte after an odd-sized chunk" do
      format = Wavify::Core::Format.new(channels: 1, sample_rate: 44_100, bit_depth: 8, sample_format: :pcm)
      comm_chunk = described_class.send(:build_comm_chunk, format, 1)
      ssnd_chunk = [0, 0].pack("N2") + [0].pack("c")
      bytes = build_aiff_bytes(["COMM", comm_chunk], ["SSND", ssnd_chunk], ["JUNK", "abc"])
      bytes = bytes.byteslice(0, bytes.bytesize - 1)

      expect do
        described_class.metadata(StringIO.new(bytes))
      end.to raise_error(Wavify::InvalidFormatError, /missing padding byte/)
    end
  end

  def build_aiff_bytes(*chunks, form_type: "AIFF")
    body = +form_type
    chunks.each do |chunk_id, chunk_data|
      body << chunk_id
      body << [chunk_data.bytesize].pack("N")
      body << chunk_data
      body << "\x00" if chunk_data.bytesize.odd?
    end
    +"FORM" << [body.bytesize].pack("N") << body
  end

  def pascal_string(value)
    bytes = value.b
    data = [bytes.bytesize].pack("C") + bytes
    data << "\x00" if data.bytesize.odd?
    data
  end
end
