# frozen_string_literal: true

require "stringio"
require "tempfile"

RSpec.describe Wavify::CLI do
  let(:format) { Wavify::Core::Format.new(channels: 1, sample_rate: 8_000, bit_depth: 16, sample_format: :pcm) }

  def run_cli(argv)
    stdout = StringIO.new
    stderr = StringIO.new
    status = described_class.run(argv, stdout: stdout, stderr: stderr)
    [status, stdout.string, stderr.string]
  end

  it "prints supported formats" do
    status, stdout, stderr = run_cli(["formats"])

    expect(status).to eq(0)
    expect(stdout).to include("wav", "flac")
    expect(stderr).to eq("")
  end

  it "prints file info" do
    Tempfile.create(["wavify-cli", ".wav"]) do |file|
      buffer = Wavify::Core::SampleBuffer.new([0, 0, 0], format)
      Wavify::Codecs::Wav.write(file.path, buffer)

      status, stdout, = run_cli(["info", file.path])

      expect(status).to eq(0)
      expect(stdout).to include("8000Hz", "frames: 3")
    end
  end

  it "generates a tone file" do
    Tempfile.create(["wavify-cli-tone", ".wav"]) do |file|
      status, stdout, = run_cli(["tone", "--freq", "220", "--duration", "0.01", file.path])

      expect(status).to eq(0)
      expect(stdout).to include("wrote:")
      expect(Wavify::Audio.metadata(file.path)[:sample_frame_count]).to eq(441)
    end
  end

  it "converts between container formats" do
    Tempfile.create(["wavify-cli-source", ".wav"]) do |source|
      Tempfile.create(["wavify-cli-output", ".aiff"]) do |output|
        buffer = Wavify::Core::SampleBuffer.new([0, 100, -100], format)
        Wavify::Codecs::Wav.write(source.path, buffer)

        status, stdout, = run_cli(["convert", source.path, output.path, "--sample-rate", "16000"])

        expect(status).to eq(0)
        expect(stdout).to include("converted:")
        expect(Wavify::Audio.metadata(output.path)[:format].sample_rate).to eq(16_000)
      end
    end
  end

  it "returns an error status for invalid commands" do
    status, stdout, stderr = run_cli(["unknown"])

    expect(status).to eq(1)
    expect(stdout).to include("usage:")
    expect(stderr).to include("unknown command")
  end
end
