# frozen_string_literal: true

require "stringio"
require "tempfile"

RSpec.describe Wavify::Codecs::Registry do
  describe ".detect" do
    it "detects wav codec by extension" do
      expect(described_class.detect("demo.wav")).to eq(Wavify::Codecs::Wav)
    end

    it "prefers magic bytes over extension for reads" do
      Tempfile.create(["wavify-registry", ".flac"]) do |file|
        file.binmode
        file.write("RIFF\x24\x00\x00\x00WAVE")
        file.flush

        expect(described_class.detect_for_read(file.path)).to eq(Wavify::Codecs::Wav)
      end
    end

    it "raises in strict mode when extension and magic bytes disagree" do
      Tempfile.create(["wavify-registry", ".flac"]) do |file|
        file.binmode
        file.write("RIFF\x24\x00\x00\x00WAVE")
        file.flush

        expect do
          described_class.detect_for_read(file.path, strict: true)
        end.to raise_error(Wavify::InvalidFormatError, /codec mismatch/)
      end
    end

    it "prefers extension for writes" do
      Tempfile.create(["wavify-registry", ".flac"]) do |file|
        file.binmode
        file.write("RIFF\x24\x00\x00\x00WAVE")
        file.flush

        expect(described_class.detect_for_write(file.path)).to eq(Wavify::Codecs::Flac)
      end
    end

    it "detects raw codec by extension" do
      expect(described_class.detect("demo.raw")).to eq(Wavify::Codecs::Raw)
    end

    it "detects flac codec by extension" do
      expect(described_class.detect("demo.flac")).to eq(Wavify::Codecs::Flac)
    end

    it "detects wav codec by magic bytes from io" do
      io = StringIO.new("RIFF\x24\x00\x00\x00WAVE")
      expect(described_class.detect(io)).to eq(Wavify::Codecs::Wav)
    end

    it "detects flac codec by magic bytes from io" do
      io = StringIO.new("fLaCtest")
      expect(described_class.detect(io)).to eq(Wavify::Codecs::Flac)
    end

    it "detects ogg codec by magic bytes from io" do
      io = StringIO.new("OggStest")
      expect(described_class.detect(io)).to eq(Wavify::Codecs::OggVorbis)
    end

    it "detects aiff codec by magic bytes from io" do
      io = StringIO.new("FORM\x00\x00\x00\x00AIFF")
      expect(described_class.detect(io)).to eq(Wavify::Codecs::Aiff)
    end

    it "detects aiff-c codec by extension and magic bytes" do
      expect(described_class.detect("demo.aifc")).to eq(Wavify::Codecs::Aiff)

      io = StringIO.new("FORM\x00\x00\x00\x00AIFC")
      expect(described_class.detect(io)).to eq(Wavify::Codecs::Aiff)
    end

    it "uses a filename hint for IO inputs without magic bytes" do
      io = StringIO.new("raw sample bytes")

      expect(described_class.detect_for_read(io, filename: "clip.raw")).to eq(Wavify::Codecs::Raw)
      expect(Wavify::Codecs.detect(io, filename: "clip.raw")).to eq(Wavify::Codecs::Raw)
    end

    it "does not consume non-rewindable IO during detection" do
      io_class = Class.new do
        attr_reader :read_count

        def initialize
          @read_count = 0
        end

        def read(*)
          @read_count += 1
          "RIFF\x24\x00\x00\x00WAVE"
        end
      end
      hinted = io_class.new
      unhinted = io_class.new

      expect(described_class.detect_for_read(hinted, filename: "clip.wav")).to eq(Wavify::Codecs::Wav)
      expect(hinted.read_count).to eq(0)
      expect do
        described_class.detect_for_read(unhinted)
      end.to raise_error(Wavify::InvalidParameterError, /rewindable IO/)
      expect(unhinted.read_count).to eq(0)
    end

    it "checks filename hints against magic bytes in strict mode" do
      io = StringIO.new("RIFF\x24\x00\x00\x00WAVE")

      expect do
        described_class.detect_for_read(io, filename: "clip.flac", strict: true)
      end.to raise_error(Wavify::InvalidFormatError, /codec mismatch/)
    end

    it "raises codec not found when unsupported" do
      io = StringIO.new("not-audio")

      expect do
        described_class.detect(io)
      end.to raise_error(Wavify::CodecNotFoundError)
    end

    it "preserves the current IO position during magic detection" do
      io = StringIO.new("prefixRIFF\x00\x00\x00\x00WAVE")
      io.pos = 6

      expect(described_class.detect(io)).to eq(Wavify::Codecs::Wav)
      expect(io.pos).to eq(6)
    end

    it "handles an empty IO whose read returns nil" do
      io = Class.new do
        def read(*) = nil
        def pos = 0
        def seek(*) = 0
      end.new

      expect { described_class.detect(io) }.to raise_error(Wavify::CodecNotFoundError)
    end

    it "does not read an IO whose seek method is unusable" do
      io = Class.new do
        attr_reader :reads

        def initialize
          @reads = 0
        end

        def read(*)
          @reads += 1
          "RIFF\x00\x00\x00\x00WAVE"
        end

        def pos
          0
        end

        def seek(*)
          raise Errno::ESPIPE
        end
      end.new

      expect(described_class.detect(io, filename: "input.wav")).to eq(Wavify::Codecs::Wav)
      expect(io.reads).to eq(0)
    end
  end


  describe ".resolve" do
    it "resolves registered names and codec classes" do
      expect(described_class.resolve(:wav)).to eq(Wavify::Codecs::Wav)
      expect(described_class.resolve(Wavify::Codecs::Flac)).to eq(Wavify::Codecs::Flac)
    end
  end

  describe "public registry helpers" do
    it "lists supported formats" do
      expect(described_class.supported_formats).to include("wav", "flac", "ogg", "raw")
      expect(Wavify::Codecs.supported_formats).to include("wav", "flac", "ogg", "raw")
    end

    it "lists dependency-available formats" do
      expect(described_class.available_formats).to include("wav", "flac", "raw")
      expect(Wavify::Codecs.available_formats).to include("wav", "flac", "raw")
    end

    it "registers custom extension mappings" do
      codec = Class.new do
        class << self
          def read(*); end
          def write(*); end
          def stream_read(*); end
          def stream_write(*); end
          def metadata(*); end
        end
      end

      expect(Wavify::Codecs.register(".demoaudio", codec)).to eq(codec)
      expect(Wavify::Codecs.detect("song.demoaudio")).to eq(codec)
      expect(Wavify::Codecs.supported_formats).to include("demoaudio")
      expect(Wavify::Codecs.unregister(".demoaudio")).to eq(codec)
      expect(Wavify::Codecs.supported_formats).not_to include("demoaudio")
    end

    it "registers custom magic probes with explicit priority" do
      codec = Class.new do
        class << self
          def read(*); end
          def write(*); end
          def stream_read(*); end
          def stream_write(*); end
          def metadata(*); end
        end
      end

      described_class.register(".custom", codec, magic: "CSTM", priority: 10)
      io = StringIO.new("prefixCSTMpayload")
      io.pos = 6

      expect(described_class.detect(io)).to eq(codec)
      expect(io.pos).to eq(6)
      expect(Wavify::Codecs.register(".custom", codec, magic: ->(bytes) { bytes.start_with?("CSTM") }, priority: 5))
        .to eq(codec)
    ensure
      described_class.unregister(".custom")
    end

    it "rejects codec methods whose signatures cannot satisfy the common contract" do
      codec = Class.new do
        class << self
          def read; end
          def write; end
          def stream_read; end
          def stream_write; end
          def metadata; end
        end
      end

      expect do
        described_class.register(".broken", codec)
      end.to raise_error(Wavify::InvalidParameterError, /signatures/)
    end

    it "requires custom probes to be bounded and boolean-valued" do
      codec = Class.new do
        class << self
          def read(*); end
          def write(*); end
          def stream_read(*); end
          def stream_write(*); end
          def metadata(*); end
        end
      end

      expect do
        described_class.register(".badprobe", codec, magic: "X", probe_size: 100_000)
      end.to raise_error(Wavify::InvalidParameterError, /probe_size/)

      described_class.register(".badprobe", codec, magic: ->(_bytes) { :yes })
      expect do
        described_class.detect(StringIO.new("anything"))
      end.to raise_error(Wavify::InvalidParameterError, /boolean/)
    ensure
      described_class.unregister(".badprobe")
    end
  end
end
