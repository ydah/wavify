# frozen_string_literal: true

RSpec.describe Wavify::DSP::Processor do
  let(:format) do
    Wavify::Core::Format.new(channels: 1, sample_rate: 8_000, bit_depth: 32, sample_format: :float)
  end

  def processor_chain
    Wavify::DSP::Effects::EffectChain.new([
      Wavify::DSP::Effects::Delay.new(time: 3.0 / 8_000, feedback: 0.25, mix: 0.4),
      Wavify::DSP::Effects::Compressor.new(threshold: -12.0, ratio: 3.0, attack: 0.001, release: 0.01),
      Wavify::DSP::Effects::Limiter.new(ceiling: -1.0, attack: 0.0, lookahead: 2.0 / 8_000)
    ])
  end

  def render_streaming(processor, source, chunk_sizes)
    chunks = []
    offset = 0
    chunk_sizes.each do |size|
      break if offset >= source.sample_frame_count

      length = [size, source.sample_frame_count - offset].min
      chunks << processor.process(source.slice(offset, length))
      offset += length
    end
    chunks << processor.process(source.slice(offset, source.sample_frame_count - offset)) if offset < source.sample_frame_count
    chunks.concat(described_class.flush(processor, format: format).to_a)
    chunks.reduce { |left, right| left.concat(right) }
  end

  it "is invariant across whole, single-frame, and random chunk boundaries" do
    samples = Array.new(257) { |index| Math.sin(2.0 * Math::PI * 440 * index / format.sample_rate) * 0.9 }
    source = Wavify::Core::SampleBuffer.new(samples, format)
    whole = render_streaming(processor_chain, source, [source.sample_frame_count])
    singles = render_streaming(processor_chain, source, Array.new(source.sample_frame_count, 1))
    rng = Random.new(12_345)
    random = render_streaming(processor_chain, source, Array.new(40) { rng.rand(1..17) })

    [singles, random].each do |actual|
      expect(actual.sample_frame_count).to eq(whole.sample_frame_count)
      actual.samples.zip(whole.samples).each do |left, right|
        expect(left).to be_within(1.0e-10).of(right)
      end
    end
  end

  it "builds isolated runtimes for repeatable offline renders" do
    source = Wavify::Core::SampleBuffer.new([1.0, 0.0, 0.0], format)
    effect = Wavify::DSP::Effects::Delay.new(time: 1.0 / 8_000, feedback: 0.5, mix: 1.0)

    first = described_class.render(effect, source)
    second = described_class.render(effect, source)

    expect(second).to eq(first)
  end

  it "requires flush methods to accept the format keyword" do
    processor = Class.new do
      def process(buffer) = buffer
      def flush = nil
    end.new

    expect do
      described_class.flush(processor, format: format)
    end.to raise_error(ArgumentError)
  end

  it "passes format through dynamic flush dispatch" do
    processor = Class.new do
      attr_reader :flushed_format

      def respond_to_missing?(name, include_private = false)
        name == :flush || super
      end

      def method_missing(name, **options)
        return super unless name == :flush

        @flushed_format = options.fetch(:format)
        nil
      end
    end.new

    expect(described_class.flush(processor, format: format).to_a).to eq([])
    expect(processor.flushed_format).to equal(format)
  end

  it "does not swallow argument errors raised inside flush" do
    processor = Class.new do
      attr_reader :flush_calls

      def flush(format:)
        @flush_calls = @flush_calls.to_i + 1
        raise ArgumentError, "unknown keyword: :format after consuming #{format.sample_rate} Hz state"
      end
    end.new

    expect do
      described_class.flush(processor, format: format)
    end.to raise_error(ArgumentError, /after consuming/)
    expect(processor.flush_calls).to eq(1)
  end
end
