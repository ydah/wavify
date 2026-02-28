# frozen_string_literal: true

require "tempfile"

RSpec.describe Wavify::Core::Stream do
  let(:format) { Wavify::Core::Format.new(channels: 1, sample_rate: 44_100, bit_depth: 32, sample_format: :float) }

  def write_source_wav(samples)
    buffer = Wavify::Core::SampleBuffer.new(samples, format)
    file = Tempfile.new(["wavify_stream_source", ".wav"])
    file.close
    Wavify::Codecs::Wav.write(file.path, buffer)
    file
  end

  it "applies pipeline processors in order while streaming chunks" do
    source = write_source_wav([0.1, 0.2, 0.3, 0.4])
    stream = described_class.new(source.path, codec: Wavify::Codecs::Wav, format: format, chunk_size: 2)
    stream.pipe(lambda do |chunk|
      scaled = chunk.samples.map { |sample| sample * 2.0 }
      Wavify::Core::SampleBuffer.new(scaled, chunk.format)
    end)
    stream.pipe(lambda do |chunk|
      shifted = chunk.samples.map { |sample| sample - 0.1 }
      Wavify::Core::SampleBuffer.new(shifted, chunk.format)
    end)

    samples = stream.each_chunk.flat_map(&:samples)
    expected = [0.1, 0.3, 0.5, 0.7]
    samples.zip(expected).each do |actual, target|
      expect(actual).to be_within(0.0001).of(target)
    end
  ensure
    source&.unlink
  end

  it "writes processed stream output to another codec" do
    source = write_source_wav([0.2, 0.4, 0.6, 0.8])
    output = Tempfile.new(["wavify_stream_out", ".wav"])
    output.close

    stream = described_class.new(source.path, codec: Wavify::Codecs::Wav, format: format, chunk_size: 2)
    stream.pipe(lambda do |chunk|
      reduced = chunk.samples.map { |sample| sample * 0.5 }
      Wavify::Core::SampleBuffer.new(reduced, chunk.format)
    end)
    stream.write_to(output.path)

    processed = Wavify::Codecs::Wav.read(output.path)
    processed.samples.zip([0.1, 0.2, 0.3, 0.4]).each do |actual, target|
      expect(actual).to be_within(0.0001).of(target)
    end
  ensure
    source&.unlink
    output&.unlink
  end

  it "supports processor objects with #process" do
    source = write_source_wav([0.1, 0.2, 0.3, 0.4])
    processor = Class.new do
      def process(chunk)
        chunk.reverse
      end
    end.new

    stream = described_class.new(source.path, codec: Wavify::Codecs::Wav, format: format, chunk_size: 4)
    stream.pipe(processor)
    chunk = stream.each_chunk.first

    chunk.samples.zip([0.4, 0.3, 0.2, 0.1]).each do |actual, target|
      expect(actual).to be_within(0.0001).of(target)
    end
  ensure
    source&.unlink
  end

  it "supports processor objects with #apply and Audio return values" do
    source = write_source_wav([0.1, 0.2, 0.3, 0.4])
    processor = Class.new do
      def apply(chunk)
        Wavify::Audio.new(chunk.reverse)
      end
    end.new

    stream = described_class.new(source.path, codec: Wavify::Codecs::Wav, format: format, chunk_size: 4)
    stream.pipe(processor)
    chunk = stream.each_chunk.first

    chunk.samples.zip([0.4, 0.3, 0.2, 0.1]).each do |actual, target|
      expect(actual).to be_within(0.0001).of(target)
    end
  ensure
    source&.unlink
  end

  it "rejects invalid processors" do
    stream = described_class.new("unused", codec: Wavify::Codecs::Wav, format: format, chunk_size: 2)

    expect do
      stream.pipe(Object.new)
    end.to raise_error(Wavify::InvalidParameterError, /processor must respond/)
  end

  it "raises when a processor returns an unsupported object" do
    source = write_source_wav([0.1, 0.2])
    stream = described_class.new(source.path, codec: Wavify::Codecs::Wav, format: format, chunk_size: 2)
    stream.pipe(->(_chunk) { :invalid })

    expect do
      stream.each_chunk.to_a
    end.to raise_error(Wavify::ProcessingError, /must return Core::SampleBuffer or Audio/)
  ensure
    source&.unlink
  end

  it "requires format when writing raw output if stream format is unknown" do
    chunk = Wavify::Core::SampleBuffer.new([0.1, 0.2], format)
    fake_codec = Class.new do
      class << self
        attr_accessor :chunk

        def stream_read(_source, chunk_size:)
          raise "unexpected chunk_size" unless chunk_size == 2

          yield chunk
        end
      end
    end
    fake_codec.chunk = chunk

    stream = described_class.new(:source, codec: fake_codec, format: nil, chunk_size: 2)

    expect do
      stream.write_to("out.raw")
    end.to raise_error(Wavify::InvalidFormatError, /format is required when writing raw/)
  end

  it "passes nil target format through for non-raw custom codec outputs when format is unknown" do
    chunk = Wavify::Core::SampleBuffer.new([0.1, 0.2], format)
    fake_codec = Class.new do
      class << self
        attr_accessor :captured_format, :chunk

        def stream_read(_source, chunk_size:)
          raise "unexpected chunk_size" unless chunk_size == 2

          yield chunk
        end

        def stream_write(io, format:)
          self.captured_format = format
          yield(->(written_chunk) { io << written_chunk })
        end
      end
    end
    fake_codec.chunk = chunk
    sink = []
    stream = described_class.new(:source, codec: fake_codec, format: nil, chunk_size: 2)

    result = stream.write_to(sink)

    expect(result).to eq(sink)
    expect(fake_codec.captured_format).to be_nil
    expect(sink.length).to eq(1)
    expect(sink.first).to be_a(Wavify::Core::SampleBuffer)
  end
end
