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

    it "uses a filename hint for IO inputs without magic bytes" do
      io = StringIO.new("raw sample bytes")

      expect(described_class.detect_for_read(io, filename: "clip.raw")).to eq(Wavify::Codecs::Raw)
      expect(Wavify::Codecs.detect(io, filename: "clip.raw")).to eq(Wavify::Codecs::Raw)
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
    end
  end
end
