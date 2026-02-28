# frozen_string_literal: true

require "tempfile"

RSpec.describe Wavify::Audio do
  let(:format) { Wavify::Core::Format.new(channels: 2, sample_rate: 44_100, bit_depth: 16, sample_format: :pcm) }

  describe ".silence" do
    it "builds silent audio for the requested duration" do
      audio = described_class.silence(0.5, format: format)

      expect(audio.sample_frame_count).to eq(22_050)
      expect(audio.buffer.samples.uniq).to eq([0])
    end
  end

  describe "read/write" do
    it "writes and reads wav files through registry" do
      source_buffer = Wavify::Core::SampleBuffer.new([100, -100, 200, -200], format)
      source_audio = described_class.new(source_buffer)

      Tempfile.create(["wavify_audio", ".wav"]) do |file|
        source_audio.write(file.path)
        loaded = described_class.read(file.path)

        expect(loaded.format).to eq(format)
        expect(loaded.buffer.samples).to eq(source_buffer.samples)
      end
    end

    it "reads OGG Vorbis through registry with codec-specific placeholder decode options" do
      audio = described_class.read(
        "spec/fixtures/audio/stereo_vorbis_44100.ogg",
        codec_options: { decode_mode: :placeholder }
      )

      expect(audio).to be_a(described_class)
      expect(audio.format.channels).to eq(2)
      expect(audio.format.sample_rate).to eq(44_100)
      expect(audio.sample_frame_count).to be > 0
      expect(audio.buffer.samples.any? { |sample| sample != 0.0 }).to eq(true)
    end
  end

  describe ".stream" do
    it "builds a Core::Stream for chunk processing" do
      source_buffer = Wavify::Core::SampleBuffer.new([100, -100, 200, -200], format)

      Tempfile.create(["wavify_audio_stream", ".wav"]) do |file|
        Wavify::Codecs::Wav.write(file.path, source_buffer)

        stream = described_class.stream(file.path, chunk_size: 1)
        expect(stream).to be_a(Wavify::Core::Stream)
        expect(stream.each_chunk.map(&:sample_frame_count)).to eq([1, 1])
      end
    end

    it "passes codec-specific stream_read options through Core::Stream" do
      metadata = Wavify::Codecs::OggVorbis.metadata("spec/fixtures/audio/stereo_vorbis_44100.ogg")
      stream = described_class.stream(
        "spec/fixtures/audio/stereo_vorbis_44100.ogg",
        chunk_size: 256,
        codec_options: { decode_mode: :placeholder }
      )

      chunks = stream.each_chunk.to_a
      expect(chunks).not_to be_empty
      expect(chunks).to all(be_a(Wavify::Core::SampleBuffer))
      expect(chunks.sum(&:sample_frame_count)).to eq(metadata[:sample_frame_count])
    end
  end

  describe ".mix" do
    it "mixes multiple audios and clips summed amplitude" do
      a = described_class.new(Wavify::Core::SampleBuffer.new([0.4, 0.4, 0.4, 0.4], format.with(sample_format: :float, bit_depth: 32)))
      b = described_class.new(Wavify::Core::SampleBuffer.new([0.8, 0.8, -0.8, -0.8], format.with(sample_format: :float, bit_depth: 32)))

      mixed = described_class.mix(a, b)

      expect(mixed.sample_frame_count).to eq(2)
      expect(mixed.buffer.samples[0]).to be_within(0.0001).of(1.0)
      expect(mixed.buffer.samples[2]).to be_within(0.0001).of(-0.4)
    end

    it "raises when sample rates differ" do
      f1 = Wavify::Core::Format.new(channels: 1, sample_rate: 44_100, bit_depth: 32, sample_format: :float)
      f2 = Wavify::Core::Format.new(channels: 1, sample_rate: 48_000, bit_depth: 32, sample_format: :float)
      a = described_class.new(Wavify::Core::SampleBuffer.new([0.1, 0.2], f1))
      b = described_class.new(Wavify::Core::SampleBuffer.new([0.1, 0.2], f2))

      expect do
        described_class.mix(a, b)
      end.to raise_error(Wavify::InvalidParameterError)
    end
  end

  describe "#convert" do
    it "returns a new audio with converted format" do
      source = described_class.new(Wavify::Core::SampleBuffer.new([100, -100], format.with(channels: 1)))
      target_format = Wavify::Core::Format.new(channels: 1, sample_rate: 48_000, bit_depth: 32, sample_format: :float)

      converted = source.convert(target_format)

      expect(converted).not_to equal(source)
      expect(converted.format).to eq(target_format)
    end
  end

  describe "#split" do
    it "splits audio at a time offset in seconds" do
      source = described_class.new(
        Wavify::Core::SampleBuffer.new([1, -1, 2, -2, 3, -3, 4, -4], format)
      )
      left, right = source.split(at: (1.0 / 44_100))

      expect(left.sample_frame_count).to eq(1)
      expect(right.sample_frame_count).to eq(3)
      expect(left.buffer.samples).to eq([1, -1])
      expect(right.buffer.samples).to eq([2, -2, 3, -3, 4, -4])
    end
  end

  describe "#loop" do
    it "repeats audio content the requested number of times" do
      source = described_class.new(Wavify::Core::SampleBuffer.new([10, -10, 20, -20], format))
      looped = source.loop(times: 3)

      expect(looped.sample_frame_count).to eq(6)
      expect(looped.buffer.samples).to eq([10, -10, 20, -20] * 3)
      expect(source.buffer.samples).to eq([10, -10, 20, -20])
    end
  end
end
