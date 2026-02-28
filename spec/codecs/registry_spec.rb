# frozen_string_literal: true

require "stringio"

RSpec.describe Wavify::Codecs::Registry do
  describe ".detect" do
    it "detects wav codec by extension" do
      expect(described_class.detect("demo.wav")).to eq(Wavify::Codecs::Wav)
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

    it "raises codec not found when unsupported" do
      io = StringIO.new("not-audio")

      expect do
        described_class.detect(io)
      end.to raise_error(Wavify::CodecNotFoundError)
    end
  end
end
