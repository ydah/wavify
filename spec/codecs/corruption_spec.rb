# frozen_string_literal: true

require "tempfile"

RSpec.describe "codec corruption handling" do
  def write_tempfile(extension, bytes)
    Tempfile.create(["wavify-corrupt", extension]) do |file|
      file.binmode
      file.write(bytes)
      file.flush
      yield file.path
    end
  end

  it "raises Wavify errors for truncated header-like inputs" do
    cases = [
      [".wav", "RIFF\x24\x00\x00\x00WAVEfmt ".b],
      [".aiff", "FORM\x00\x00\x00\x08AIFF".b],
      [".flac", "fLaC\x80\x00\x00".b]
    ]

    cases.each do |extension, bytes|
      write_tempfile(extension, bytes) do |path|
        expect { Wavify::Audio.read(path) }.to raise_error(Wavify::Error), extension
        expect { Wavify::Audio.metadata(path) }.to raise_error(Wavify::Error), extension
      end
    end
  end

  it "raises Wavify errors for truncated OGG inputs", :ogg do
    write_tempfile(".ogg", "OggS\x00\x02truncated".b) do |path|
      expect { Wavify::Audio.read(path) }.to raise_error(Wavify::Error)
      expect { Wavify::Audio.metadata(path) }.to raise_error(Wavify::Error)
    end
  end
end
