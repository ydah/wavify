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

  it "exposes pipeline processors in execution order without allowing mutation" do
    stream = described_class.new("unused", codec: Wavify::Codecs::Wav, format: format, chunk_size: 2)
    processor = ->(chunk) { chunk }

    stream.pipe(processor, name: :identity)
    snapshot = stream.pipeline
    snapshot.clear

    expect(stream.pipeline).to eq([processor])
    expect(stream.pipeline_steps).to eq([{ name: "identity", processor: processor }])
  end

  it "maps chunks with a named block processor" do
    source = write_source_wav([0.1, 0.2, 0.3, 0.4])
    stream = described_class.new(source.path, codec: Wavify::Codecs::Wav, format: format, chunk_size: 2)

    stream.map_chunks(name: :double) do |chunk|
      Wavify::Core::SampleBuffer.new(chunk.samples.map { |sample| sample * 2.0 }, chunk.format)
    end

    expect(stream.pipeline_steps.first[:name]).to eq("double")
    stream.each_chunk.flat_map(&:samples).zip([0.2, 0.4, 0.6, 0.8]).each do |actual, target|
      expect(actual).to be_within(0.0001).of(target)
    end
  ensure
    source&.unlink
  end

  it "materializes dropped and limited stream windows into Audio" do
    source = write_source_wav([0.1, 0.2, 0.3, 0.4, 0.5])
    stream = described_class.new(source.path, codec: Wavify::Codecs::Wav, format: format, chunk_size: 2)

    audio = stream.drop_duration(1.0 / format.sample_rate).take_duration(3.0 / format.sample_rate).to_audio

    expect(audio).to be_a(Wavify::Audio)
    audio.buffer.samples.zip([0.2, 0.3, 0.4]).each do |actual, target|
      expect(actual).to be_within(0.0001).of(target)
    end
  ensure
    source&.unlink
  end

  it "reports chunk meters and cumulative progress without changing audio" do
    source = write_source_wav([0.25, -0.5, 0.5, -0.25])
    meters = []
    progresses = []
    stream = described_class.new(source.path, codec: Wavify::Codecs::Wav, format: format, chunk_size: 2)
    stream.meter { |stats| meters << stats }
    stream.progress(total_frames: 4) { |stats| progresses << stats }

    samples = stream.each_chunk.flat_map(&:samples)

    expect(samples).to eq([0.25, -0.5, 0.5, -0.25])
    expect(meters.map { |stats| stats[:sample_frame_count] }).to eq([2, 2])
    expect(meters.map { |stats| stats[:peak_amplitude] }).to all(be_within(0.0001).of(0.5))
    expect(progresses.map { |stats| stats[:sample_frame_count] }).to eq([2, 4])
    expect(progresses.last[:progress]).to eq(1.0)
  ensure
    source&.unlink
  end

  it "tees processed chunks to an additional output" do
    source = write_source_wav([0.2, 0.4, 0.6, 0.8])
    tee_output = Tempfile.new(["wavify_stream_tee", ".wav"])
    tee_output.close
    stream = described_class.new(source.path, codec: Wavify::Codecs::Wav, format: format, chunk_size: 2)
    stream.map_chunks do |chunk|
      Wavify::Core::SampleBuffer.new(chunk.samples.map { |sample| sample * 0.5 }, chunk.format)
    end

    stream.tee(tee_output.path).each_chunk.to_a

    written = Wavify::Codecs::Wav.read(tee_output.path)
    written.samples.zip([0.1, 0.2, 0.3, 0.4]).each do |actual, target|
      expect(actual).to be_within(0.0001).of(target)
    end
  ensure
    source&.unlink
    tee_output&.unlink
  end

  it "resets stateful processors before each stream pass" do
    source = write_source_wav([0.1, 0.2])
    processor = Class.new do
      attr_reader :reset_count

      def initialize
        @reset_count = 0
      end

      def reset
        @reset_count += 1
      end

      def process(chunk)
        chunk
      end
    end.new

    stream = described_class.new(source.path, codec: Wavify::Codecs::Wav, format: format, chunk_size: 1)
    stream.pipe(processor)

    2.times { stream.each_chunk.to_a }

    expect(processor.reset_count).to eq(2)
  ensure
    source&.unlink
  end

  it "flushes tail chunks through downstream processors after input ends" do
    source = write_source_wav([0.25])
    tailing = Class.new do
      def process(chunk)
        chunk
      end

      def flush(format:)
        Wavify::Core::SampleBuffer.new([0.5], format)
      end
    end.new
    downstream = lambda do |chunk|
      Wavify::Core::SampleBuffer.new(chunk.samples.map { |sample| sample * 2.0 }, chunk.format)
    end

    stream = described_class.new(source.path, codec: Wavify::Codecs::Wav, format: format, chunk_size: 1)
    stream.pipe(tailing).pipe(downstream)

    samples = stream.each_chunk.flat_map(&:samples)

    expect(samples).to eq([0.5, 1.0])
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

  it "passes codec-specific write options to the output codec" do
    chunk = Wavify::Core::SampleBuffer.new([0.1, 0.2], format)
    fake_codec = Class.new do
      class << self
        attr_accessor :captured_options, :chunk

        def stream_read(_source, chunk_size:)
          raise "unexpected chunk_size" unless chunk_size == 2

          yield chunk
        end

        def stream_write(io, format:, **options)
          self.captured_options = options
          yield(->(written_chunk) { io << [format, written_chunk] })
        end
      end
    end
    fake_codec.chunk = chunk
    sink = []
    stream = described_class.new(:source, codec: fake_codec, format: format, chunk_size: 2)

    stream.write_to(sink, codec_options: { block_size: 2, block_size_strategy: :fixed })

    expect(fake_codec.captured_options).to eq(block_size: 2, block_size_strategy: :fixed)
    expect(sink.length).to eq(1)
  end
end
