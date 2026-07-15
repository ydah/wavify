# frozen_string_literal: true

require "tempfile"

RSpec.describe "codec golden round trips" do
  let(:format) { Wavify::Core::Format.new(channels: 2, sample_rate: 22_050, bit_depth: 16, sample_format: :pcm) }
  let(:samples) { [0, 1_000, -1_000, 2_000, -2_000, 3_000, -3_000, 4_000] }
  let(:audio) { Wavify::Audio.new(Wavify::Core::SampleBuffer.new(samples, format)) }

  it "round-trips small deterministic PCM fixtures through core codecs" do
    {
      ".wav" => {},
      ".aiff" => {},
      ".flac" => { codec_options: { block_size: 2 } }
    }.each do |extension, write_options|
      Tempfile.create(["wavify-golden", extension]) do |file|
        file.close
        audio.write(file.path, **write_options)
        loaded = Wavify::Audio.read(file.path)

        expect(loaded.format).to eq(format), extension
        expect(loaded.buffer.samples).to eq(samples), extension
        expect(loaded.duration.total_seconds).to eq(audio.duration.total_seconds), extension
      end
    end
  end

  it "round-trips raw PCM when explicit format metadata is supplied" do
    Tempfile.create(["wavify-golden", ".raw"]) do |file|
      file.close
      audio.write(file.path, format: format)
      loaded = Wavify::Audio.read(file.path, format: format)

      expect(loaded.format).to eq(format)
      expect(loaded.buffer.samples).to eq(samples)
      expect(Wavify::Audio.metadata(file.path, format: format)[:sample_frame_count]).to eq(audio.sample_frame_count)
    end
  end
end
