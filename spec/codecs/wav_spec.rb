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

    it "writes and reads LIST/INFO metadata" do
      format = Wavify::Core::Format.new(channels: 1, sample_rate: 44_100, bit_depth: 16, sample_format: :pcm)
      buffer = Wavify::Core::SampleBuffer.new([100, -100], format)

      Tempfile.create(["wavify_info", ".wav"]) do |file|
        described_class.write(file.path, buffer, info: { title: "Bell", artist: "Wavify", "ICMT" => "demo" })

        metadata = described_class.metadata(file.path)

        expect(metadata[:info][:title]).to eq("Bell")
        expect(metadata[:info][:artist]).to eq("Wavify")
        expect(metadata[:info][:comment]).to eq("demo")
        expect(metadata[:info][:raw]["INAM"]).to eq("Bell")
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
        expect(metadata[:loops]).to eq([
          {
            identifier: 7,
            type: :forward,
            start_frame: 10,
            end_frame: 100,
            length_frames: 91,
            play_count: 2
          }
        ])
      end
    end

    it "parses cue points when cue chunk exists" do
      fmt_chunk = [1, 1, 44_100, 44_100, 1, 8].pack("v v V V v v")
      cue_chunk = [1, 42, 0, "data", 0, 0, 123].pack("V V V A4 V V V")
      data_chunk = [128, 128, 128, 128].pack("C*")
      bytes = build_wave_bytes(
        ["fmt ", fmt_chunk],
        ["cue ", cue_chunk],
        ["data", data_chunk]
      )

      Tempfile.create(["wavify-cue", ".wav"]) do |file|
        file.binmode
        file.write(bytes)
        file.flush

        metadata = described_class.metadata(file.path)
        expect(metadata[:cue][:cue_count]).to eq(1)
        expect(metadata[:cue_points]).to eq([
          {
            identifier: 42,
            position: 0,
            data_chunk_id: "data",
            chunk_start: 0,
            block_start: 0,
            sample_offset: 123
          }
        ])
      end
    end

    it "parses Broadcast WAV bext metadata" do
      fmt_chunk = [1, 1, 48_000, 48_000, 1, 8].pack("v v V V v v")
      bext_chunk = build_bext_chunk(
        description: "Field recording",
        originator: "Wavify",
        originator_reference: "take-001",
        date: "2026-05-16",
        time: "12:34:56",
        time_reference: 1234,
        coding_history: "A=PCM,F=48000,W=8,M=mono"
      )
      data_chunk = [128, 129].pack("C*")
      bytes = build_wave_bytes(
        ["fmt ", fmt_chunk],
        ["bext", bext_chunk],
        ["data", data_chunk]
      )

      Tempfile.create(["wavify-bext", ".wav"]) do |file|
        file.binmode
        file.write(bytes)
        file.flush

        metadata = described_class.metadata(file.path)
        expect(metadata[:bext]).to include(
          description: "Field recording",
          originator: "Wavify",
          originator_reference: "take-001",
          origination_date: "2026-05-16",
          origination_time: "12:34:56",
          time_reference: 1234,
          version: 1,
          coding_history: "A=PCM,F=48000,W=8,M=mono"
        )
        expect(metadata[:broadcast_extension]).to eq(metadata[:bext])
      end
    end

    it "reads small RF64 files using ds64 chunk sizes" do
      fmt_chunk = [1, 1, 8_000, 8_000, 1, 8].pack("v v V V v v")
      data_chunk = [128, 129, 130, 131].pack("C*")
      bytes = build_rf64_bytes(
        data_size: data_chunk.bytesize,
        sample_frame_count: data_chunk.bytesize,
        chunks: [
          ["fmt ", fmt_chunk],
          ["data", data_chunk]
        ]
      )

      Tempfile.create(["wavify-rf64", ".wav"]) do |file|
        file.binmode
        file.write(bytes)
        file.flush

        metadata = described_class.metadata(file.path)
        decoded = described_class.read(file.path)
        expect(metadata[:rf64]).to include(data_size: 4, sample_frame_count: 4)
        expect(decoded.samples).to eq([0, 1, 2, 3])
      end
    end

    it "derives RF64 frame count when ds64 leaves it as zero" do
      fmt_chunk = [1, 1, 8_000, 16_000, 2, 16].pack("v v V V v v")
      data = [0, 1, 2].pack("s<*")
      bytes = build_rf64_bytes(
        data_size: data.bytesize,
        sample_frame_count: 0,
        chunks: [["fmt ", fmt_chunk], ["data", data]]
      )

      Tempfile.create(["wavify-rf64-zero-count", ".wav"]) do |file|
        file.binmode
        file.write(bytes)
        file.flush

        expect(described_class.metadata(file.path)[:sample_frame_count]).to eq(3)
      end
    end

    it "accepts extensible PCM with fewer valid bits than its container" do
      guid_tail = [0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71].pack("C*")
      pcm_guid = [1, 0, 0x10].pack("V v v") + guid_tail
      fmt_chunk = [0xFFFE, 1, 8_000, 32_000, 4, 32, 22, 24, 4].pack("v v V V v v v v V") + pcm_guid
      bytes = build_wave_bytes(["fmt ", fmt_chunk], ["data", [0, 0x7FFFFF00].pack("l<*")])

      Tempfile.create(["wavify-valid-bits", ".wav"]) do |file|
        file.binmode
        file.write(bytes)
        file.flush

        metadata = described_class.metadata(file.path)
        expect(metadata[:format].bit_depth).to eq(32)
        expect(metadata[:container_bit_depth]).to eq(32)
        expect(metadata[:valid_bits_per_sample]).to eq(24)
        expect(described_class.read(file.path).samples).to eq([0, 0x7FFFFF00])
      end
    end

    it "strips repeated NUL padding from WAV strings" do
      fmt_chunk = [1, 1, 8_000, 8_000, 1, 8].pack("v v V V v v")
      list_data = "INFO" + "INAM" + [8].pack("V") + "Title\x00\x00\x00"
      bytes = build_wave_bytes(["fmt ", fmt_chunk], ["LIST", list_data], ["data", "\x80"])

      Tempfile.create(["wavify-info-padding", ".wav"]) do |file|
        file.binmode
        file.write(bytes)
        file.flush

        expect(described_class.metadata(file.path).dig(:info, :title)).to eq("Title")
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

    it "raises explicitly when RIFF output sizes overflow" do
      expect do
        described_class.send(:validate_riff_sizes!, 0x1_0000_0000, 1, 16)
      end.to raise_error(Wavify::UnsupportedFormatError, /RF64 writing/)
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

  def build_rf64_bytes(data_size:, sample_frame_count:, chunks:)
    ds64 = [0, data_size, sample_frame_count, 0].pack("Q< Q< Q< V")
    body = +"WAVE"
    body << "ds64" << [ds64.bytesize].pack("V") << ds64
    chunks.each do |chunk_id, chunk_data|
      declared_size = chunk_id == "data" ? 0xFFFF_FFFF : chunk_data.bytesize
      body << chunk_id
      body << [declared_size].pack("V")
      body << chunk_data
      body << "\x00" if chunk_data.bytesize.odd?
    end

    +"RF64" << [0xFFFF_FFFF].pack("V") << body
  end

  def build_bext_chunk(description:, originator:, originator_reference:, date:, time:, time_reference:, coding_history:)
    fixed = +""
    fixed << description.ljust(256, "\x00")
    fixed << originator.ljust(32, "\x00")
    fixed << originator_reference.ljust(32, "\x00")
    fixed << date.ljust(10, "\x00")
    fixed << time.ljust(8, "\x00")
    fixed << [time_reference].pack("Q<")
    fixed << [1].pack("v")
    fixed << ("\x00" * 64)
    fixed << [0, 0, 0, 0, 0].pack("s<5")
    fixed << ("\x00" * 180)
    fixed << coding_history
    fixed
  end
end
