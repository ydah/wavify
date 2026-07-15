# frozen_string_literal: true

require "tempfile"

RSpec.describe "streaming and offline consistency" do
  let(:format) { Wavify::Core::Format.new(channels: 2, sample_rate: 8_000, bit_depth: 16, sample_format: :pcm) }
  let(:samples) { [-3_000, 3_000, -1_500, 1_500, 0, 0, 1_500, -1_500, 3_000, -3_000, 0, 0] }
  let(:source) { Wavify::Audio.new(Wavify::Core::SampleBuffer.new(samples, format)) }

  it "matches offline gain processing for chunked write pipelines" do
    Tempfile.create(["wavify-stream-source", ".wav"]) do |input|
      Tempfile.create(["wavify-stream-output", ".wav"]) do |output|
        input.close
        output.close
        source.write(input.path)

        stream_gain = lambda do |buffer|
          Wavify::Audio.new(buffer).gain(-6.0).buffer
        end
        Wavify::Audio.stream(input.path, chunk_size: 2)
                     .pipe(stream_gain, name: :gain)
                     .write_to(output.path, format: format)

        offline = source.gain(-6.0)
        streamed = Wavify::Audio.read(output.path)

        expect(streamed.format).to eq(offline.format)
        expect(streamed.sample_frame_count).to eq(offline.sample_frame_count)
        streamed.buffer.samples.zip(offline.buffer.samples).each do |actual, expected|
          expect(actual).to be_within(1).of(expected)
        end
      end
    end
  end
end
