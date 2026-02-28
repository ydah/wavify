# frozen_string_literal: true

require "tempfile"

RSpec.describe Wavify::Codecs::Wav do
  describe ".can_read?" do
    it "returns true for wav extension" do
      expect(described_class.can_read?("sample.wav")).to be(true)
    end

    it "returns false for unsupported input" do
      expect(described_class.can_read?("sample.mp3")).to be(false)
    end
  end

  describe "roundtrip encoding/decoding" do
    it "roundtrips 16-bit pcm stereo" do
      format = Wavify::Core::Format.new(channels: 2, sample_rate: 44_100, bit_depth: 16, sample_format: :pcm)
      buffer = Wavify::Core::SampleBuffer.new([1000, -1000, 20_000, -20_000], format)

      Tempfile.create(["wavify", ".wav"]) do |file|
        described_class.write(file.path, buffer)
        decoded = described_class.read(file.path)

        expect(decoded.format).to eq(format)
        expect(decoded.samples).to eq(buffer.samples)
      end
    end

    it "roundtrips 24-bit pcm with extensible fmt chunk" do
      format = Wavify::Core::Format.new(channels: 3, sample_rate: 48_000, bit_depth: 24, sample_format: :pcm)
      buffer = Wavify::Core::SampleBuffer.new([100, -100, 300, 500_000, -500_000, 12_345], format)

      Tempfile.create(["wavify", ".wav"]) do |file|
        described_class.write(file.path, buffer)
        header = File.binread(file.path, 40)
        format_code = header[20, 2].unpack1("v")

        expect(format_code).to eq(described_class::WAV_FORMAT_EXTENSIBLE)

        decoded = described_class.read(file.path)
        expect(decoded.format).to eq(format)
        expect(decoded.samples).to eq(buffer.samples)
      end
    end

    it "roundtrips 32-bit float stereo" do
      format = Wavify::Core::Format.new(channels: 2, sample_rate: 44_100, bit_depth: 32, sample_format: :float)
      buffer = Wavify::Core::SampleBuffer.new([0.25, -0.25, 0.75, -0.75], format)

      Tempfile.create(["wavify", ".wav"]) do |file|
        described_class.write(file.path, buffer)
        decoded = described_class.read(file.path)

        expect(decoded.format).to eq(format)
        decoded.samples.zip(buffer.samples).each do |actual, expected|
          expect(actual).to be_within(0.0001).of(expected)
        end
      end
    end
  end

  describe ".stream_write/.stream_read" do
    it "writes and reads data in chunks" do
      format = Wavify::Core::Format.new(channels: 2, sample_rate: 44_100, bit_depth: 16, sample_format: :pcm)
      first = Wavify::Core::SampleBuffer.new([1, -1, 2, -2], format)
      second = Wavify::Core::SampleBuffer.new([3, -3, 4, -4], format)

      Tempfile.create(["wavify", ".wav"]) do |file|
        described_class.stream_write(file.path, format: format) do |writer|
          writer.call(first)
          writer.call(second)
        end

        chunks = []
        described_class.stream_read(file.path, chunk_size: 1) { |chunk| chunks << chunk }

        expect(chunks.map(&:sample_frame_count)).to eq([1, 1, 1, 1])
        expect(chunks.flat_map(&:samples)).to eq([1, -1, 2, -2, 3, -3, 4, -4])
      end
    end
  end

  describe ".metadata" do
    it "returns fact information for non-pcm output" do
      format = Wavify::Core::Format.new(channels: 2, sample_rate: 48_000, bit_depth: 32, sample_format: :float)
      buffer = Wavify::Core::SampleBuffer.new([0.5, -0.5, 0.2, -0.2], format)

      Tempfile.create(["wavify", ".wav"]) do |file|
        described_class.write(file.path, buffer)
        metadata = described_class.metadata(file.path)

        expect(metadata[:format]).to eq(format)
        expect(metadata[:sample_frame_count]).to eq(2)
        expect(metadata[:fact_sample_length]).to eq(2)
      end
    end

    it "parses smpl loops when chunk exists" do
      fmt_chunk = [1, 1, 44_100, 44_100, 1, 8].pack("v v V V v v")
      smpl_header = [0, 0, 0, 60, 0, 0, 0, 1, 0].pack("V9")
      smpl_loop = [7, 0, 10, 100, 0, 2].pack("V6")
      smpl_chunk = smpl_header + smpl_loop
      data_chunk = [128, 128, 128, 128].pack("C*")
      bytes = build_wave_bytes(
        ["fmt ", fmt_chunk],
        ["smpl", smpl_chunk],
        ["data", data_chunk]
      )

      Tempfile.create(["wavify", ".wav"]) do |file|
        file.binmode
        file.write(bytes)
        file.flush

        metadata = described_class.metadata(file.path)
        expect(metadata[:smpl]).not_to be_nil
        expect(metadata[:smpl][:loop_count]).to eq(1)
        expect(metadata[:smpl][:loops].first[:identifier]).to eq(7)
      end
    end
  end

  describe "chunk parsing behavior" do
    it "ignores extra bytes in non-extensible fmt chunk" do
      fmt_chunk = [1, 1, 8_000, 8_000, 1, 8, 0].pack("v v V V v v v")
      data_chunk = [128, 255].pack("C*")
      bytes = build_wave_bytes(
        ["fmt ", fmt_chunk],
        ["data", data_chunk]
      )

      Tempfile.create(["wavify", ".wav"]) do |file|
        file.binmode
        file.write(bytes)
        file.flush

        decoded = described_class.read(file.path)
        expect(decoded.format).to eq(Wavify::Core::Format.new(channels: 1, sample_rate: 8_000, bit_depth: 8, sample_format: :pcm))
        expect(decoded.samples).to eq([0, 127])
      end
    end

    it "skips unknown odd-sized chunks with padding" do
      fmt_chunk = [1, 1, 8_000, 8_000, 1, 8].pack("v v V V v v")
      junk_chunk = "abc"
      data_chunk = [128, 129].pack("C*")
      bytes = build_wave_bytes(
        ["fmt ", fmt_chunk],
        ["JUNK", junk_chunk],
        ["data", data_chunk]
      )

      Tempfile.create(["wavify", ".wav"]) do |file|
        file.binmode
        file.write(bytes)
        file.flush

        decoded = described_class.read(file.path)
        expect(decoded.samples).to eq([0, 1])
      end
    end
  end

  describe "error handling" do
    it "raises on invalid riff header" do
      Tempfile.create(["wavify", ".wav"]) do |file|
        file.write("NOTWAVE")
        file.flush

        expect do
          described_class.read(file.path)
        end.to raise_error(Wavify::InvalidFormatError)
      end
    end

    it "raises on truncated data chunk" do
      fmt_chunk = [1, 1, 8_000, 8_000, 1, 8].pack("v v V V v v")
      bytes = build_wave_bytes(
        ["fmt ", fmt_chunk],
        ["data", [128, 129].pack("C*")]
      )
      truncated = bytes[0, bytes.bytesize - 1]

      Tempfile.create(["wavify", ".wav"]) do |file|
        file.binmode
        file.write(truncated)
        file.flush

        expect do
          described_class.read(file.path)
        end.to raise_error(Wavify::InvalidFormatError)
      end
    end
  end

  def build_wave_bytes(*chunks)
    body = +"WAVE"
    chunks.each do |chunk_id, chunk_data|
      body << chunk_id
      body << [chunk_data.bytesize].pack("V")
      body << chunk_data
      body << "\x00" if chunk_data.bytesize.odd?
    end

    bytes = +"RIFF"
    bytes << [body.bytesize].pack("V")
    bytes << body
    bytes
  end
end
