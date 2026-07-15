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
    expect(stream.pipeline_steps).to eq([
      { name: "identity", processor: processor, latency: 0.0, lookahead: 0.0, tail_duration: 0.0 }
    ])
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

  it "stops decoding once the requested input duration is reached" do
    chunks_read = 0
    chunk = Wavify::Core::SampleBuffer.new([0.1], format)
    codec = Class.new do
      define_singleton_method(:stream_read) do |_source, chunk_size:, &block|
        raise "unexpected chunk size" unless chunk_size == 1

        100.times do
          chunks_read += 1
          block.call(chunk)
        end
      end
    end
    stream = described_class.new(:source, codec: codec, format: format, chunk_size: 1)

    audio = stream.take_duration(3.0 / format.sample_rate).to_audio

    expect(audio.sample_frame_count).to eq(3)
    expect(chunks_read).to eq(3)
  end

  it "compensates processor latency before applying take_duration" do
    source = write_source_wav([0.1, 0.2, 0.3, 0.4])
    limiter = Wavify::DSP::Effects::Limiter.new(ceiling: 0.0, attack: 0.0, lookahead: 2.0 / format.sample_rate)
    stream = described_class.new(source.path, codec: Wavify::Codecs::Wav, format: format, chunk_size: 1)

    samples = stream.pipe(limiter).take_duration(3.0 / format.sample_rate).to_audio.buffer.samples

    samples.zip([0.1, 0.2, 0.3]).each do |actual, expected|
      expect(actual).to be_within(0.000001).of(expected)
    end
  ensure
    source&.unlink
  end

  it "rewinds reusable IO sources between enumerations" do
    io = StringIO.new([1, 2, 3, 4].pack("s<*"))
    raw_format = format.with(channels: 1, sample_format: :pcm, bit_depth: 16)
    stream = described_class.new(
      io,
      codec: Wavify::Codecs::Raw,
      format: raw_format,
      chunk_size: 2,
      codec_read_options: { format: raw_format }
    )

    expect(stream.to_audio.buffer.samples).to eq([1, 2, 3, 4])
    expect(stream.to_audio.buffer.samples).to eq([1, 2, 3, 4])
  end

  it "restores a reusable IO source to its original position" do
    io = StringIO.new([99, 1, 2, 3].pack("s<*"))
    io.pos = 2
    raw_format = format.with(sample_format: :pcm, bit_depth: 16)
    stream = described_class.new(
      io,
      codec: Wavify::Codecs::Raw,
      format: raw_format,
      chunk_size: 2,
      codec_read_options: { format: raw_format }
    )

    expect(stream.to_audio.buffer.samples).to eq([1, 2, 3])
    expect(stream.to_audio.buffer.samples).to eq([1, 2, 3])
  end

  it "raises before reusing a non-rewindable IO source" do
    io_class = Class.new do
      def initialize(bytes)
        @bytes = bytes
        @read = false
      end

      def read(*)
        return nil if @read

        @read = true
        @bytes
      end
    end
    raw_format = format.with(channels: 1, sample_format: :pcm, bit_depth: 16)
    stream = described_class.new(
      io_class.new([1, 2].pack("s<*")),
      codec: Wavify::Codecs::Raw,
      format: raw_format,
      codec_read_options: { format: raw_format }
    )

    stream.to_audio
    expect do
      stream.to_audio
    end.to raise_error(Wavify::StreamError, /cannot be enumerated more than once/)
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

  it "clamps estimated progress at one" do
    source = write_source_wav([0.1, 0.2, 0.3])
    updates = []
    stream = described_class.new(source.path, codec: Wavify::Codecs::Wav, format: format, chunk_size: 3)
    stream.progress(total_frames: 2) { |stats| updates << stats }

    stream.to_audio

    expect(updates.last[:sample_frame_count]).to eq(3)
    expect(updates.last[:progress]).to eq(1.0)
  ensure
    source&.unlink
  end

  it "preserves exceptions raised by user processors" do
    error_class = Class.new(StandardError)
    source = write_source_wav([0.1, 0.2])
    stream = described_class.new(source.path, codec: Wavify::Codecs::Wav, format: format, chunk_size: 2)
    stream.meter { raise error_class, "meter failed" }

    expect do
      stream.to_a
    end.to raise_error(error_class, "meter failed")
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

  it "opens and finalizes multiple tee writers iteratively" do
    source = Wavify::Core::SampleBuffer.new([0.1, 0.2, 0.3, 0.4], format)
    input = StringIO.new(+"".b, "w+b")
    Wavify::Codecs::Wav.write(input, source, format: format)
    input.rewind
    outputs = Array.new(32) { StringIO.new(+"".b, "w+b") }

    stream = described_class.new(input, codec: Wavify::Codecs::Wav, format: nil, chunk_size: 1)
    outputs.each { |output| stream.tee(output, codec: :wav) }
    stream.each_chunk.to_a

    outputs.each do |output|
      expect(output.string).to start_with("RIFF")
      output.rewind
      decoded = Wavify::Codecs::Wav.read(output)
      decoded.samples.zip(source.samples).each do |actual, expected|
        expect(actual).to be_within(1e-6).of(expected)
      end
    end
  end

  it "dry-runs processing without writing tee outputs" do
    source = write_source_wav([0.1, 0.2, 0.3, 0.4])
    tee_output = Tempfile.new(["wavify_stream_dry_run", ".wav"])
    tee_output.close
    processor = Class.new do
      def latency
        0.01
      end

      def lookahead
        0.02
      end

      def tail_duration
        0.03
      end

      def process(chunk)
        chunk
      end
    end.new
    stream = described_class.new(source.path, codec: Wavify::Codecs::Wav, format: format, chunk_size: 2)
    stream.pipe(processor, name: :metered).tee(tee_output.path)

    before_size = File.size(tee_output.path)
    stats = stream.dry_run

    expect(stats[:chunks]).to eq(2)
    expect(stats[:sample_frame_count]).to eq(4)
    expect(stats[:duration].total_seconds).to be_within(0.0001).of(4.0 / format.sample_rate)
    expect(stats[:latency]).to eq(0.01)
    expect(stats[:lookahead]).to eq(0.02)
    expect(stats[:tail_duration]).to eq(0.03)
    expect(stats[:pipeline].first[:name]).to eq("metered")
    expect(File.size(tee_output.path)).to eq(before_size)
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

  it "applies take_duration to flushed processor tails" do
    tail_processor = Class.new do
      def process(chunk) = chunk

      def flush(format:)
        Wavify::Core::SampleBuffer.new(Array.new(8, 0), format)
      end
    end.new
    source = write_source_wav([0.1, 0.2])
    stream = described_class.new(source.path, codec: Wavify::Codecs::Wav, format: format, chunk_size: 2)
    stream.pipe(tail_processor).take_duration(3.0 / format.sample_rate)

    expect(stream.to_audio.sample_frame_count).to eq(3)
  ensure
    source&.unlink
  end

  it "rejects invalid processors" do
    stream = described_class.new("unused", codec: Wavify::Codecs::Wav, format: format, chunk_size: 2)

    expect do
      stream.pipe(Object.new)
    end.to raise_error(Wavify::InvalidParameterError, /processor must respond/)
  end

  it "rejects ambiguous processor and block arguments" do
    stream = described_class.new("unused", codec: Wavify::Codecs::Wav, format: format)

    expect do
      stream.pipe(->(chunk) { chunk }) { |chunk| chunk }
    end.to raise_error(Wavify::InvalidParameterError, /either a processor or a block/)
  end

  it "rejects non-finite duration windows" do
    stream = described_class.new("unused", codec: Wavify::Codecs::Wav, format: format)

    expect { stream.take_duration(Float::INFINITY) }.to raise_error(Wavify::InvalidParameterError, /finite/)
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

  it "adds codec, target, and chunk size context to stream read failures" do
    failing_codec = Class.new do
      def self.stream_read(_source, chunk_size:)
        raise "unexpected chunk_size" unless chunk_size == 8

        raise Wavify::InvalidFormatError, "broken stream"
      end
    end

    stream = described_class.new("input.wav", codec: failing_codec, format: format, chunk_size: 8)

    expect do
      stream.each_chunk.to_a
    end.to raise_error(Wavify::StreamError) { |error|
      expect(error.message).to include("stream read failed")
      expect(error.message).to include("codec=")
      expect(error.message).to include("target=input.wav")
      expect(error.message).to include("chunk_size=8")
      expect(error.message).to include("broken stream")
    }
  end

  it "adds codec, target, and chunk size context to stream write failures" do
    chunk = Wavify::Core::SampleBuffer.new([0.1, 0.2], format)
    failing_codec = Class.new do
      class << self
        attr_accessor :chunk

        def stream_read(_source, chunk_size:)
          raise "unexpected chunk_size" unless chunk_size == 2

          yield chunk
        end

        def stream_write(_target, format:)
          yield(->(_written_chunk) { raise IOError, "sink closed" })
        end
      end
    end
    failing_codec.chunk = chunk
    stream = described_class.new(:source, codec: failing_codec, format: format, chunk_size: 2)

    expect do
      stream.write_to(:sink)
    end.to raise_error(Wavify::StreamError) { |error|
      expect(error.message).to include("stream write failed")
      expect(error.message).to include("codec=")
      expect(error.message).to include("target=Symbol")
      expect(error.message).to include("chunk_size=2")
      expect(error.message).to include("sink closed")
    }
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

  it "writes and tees generic IO using explicit codec hints" do
    source = write_source_wav([0.1, 0.2])
    output = StringIO.new(+"".b)
    tee_output = StringIO.new(+"".b)
    stream = described_class.new(source.path, codec: Wavify::Codecs::Wav, format: format, chunk_size: 1)

    stream.tee(tee_output, codec: :wav).write_to(output, codec: :wav)

    expect(output.string).to start_with("RIFF")
    expect(tee_output.string).to start_with("RIFF")
  ensure
    source&.unlink
  end

  it "refuses to overwrite existing path output when requested" do
    source = write_source_wav([0.1, 0.2])
    output = Tempfile.new(["wavify_stream_existing", ".wav"])
    output.close
    stream = described_class.new(source.path, codec: Wavify::Codecs::Wav, format: format, chunk_size: 2)

    expect(File).not_to receive(:exist?)
    expect do
      stream.write_to(output.path, overwrite: false)
    end.to raise_error(Wavify::InvalidParameterError, /already exists/)
  ensure
    source&.unlink
    output&.unlink
  end

  it "creates a new stream output atomically when overwrite is disabled" do
    source = write_source_wav([0.1, 0.2])
    stream = described_class.new(source.path, codec: Wavify::Codecs::Wav, format: format, chunk_size: 2)

    Dir.mktmpdir do |dir|
      output = File.join(dir, "exclusive.wav")

      expect(stream.write_to(output, overwrite: false)).to eq(output)
      samples = Wavify::Audio.read(output).buffer.samples
      expect(samples.fetch(0)).to be_within(0.000_001).of(0.1)
      expect(samples.fetch(1)).to be_within(0.000_001).of(0.2)
    end
  ensure
    source&.unlink
  end
end
