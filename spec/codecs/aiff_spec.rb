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

  def build_aiff_bytes(*chunks)
    body = +"AIFF"
    chunks.each do |chunk_id, chunk_data|
      body << chunk_id
      body << [chunk_data.bytesize].pack("N")
      body << chunk_data
      body << "\x00" if chunk_data.bytesize.odd?
    end
    +"FORM" << [body.bytesize].pack("N") << body
  end
end
