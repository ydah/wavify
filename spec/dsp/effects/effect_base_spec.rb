# frozen_string_literal: true

RSpec.describe Wavify::DSP::Effects::EffectBase do
  let(:format) { Wavify::Core::Format.new(channels: 2, sample_rate: 44_100, bit_depth: 16, sample_format: :pcm) }
  let(:buffer) { Wavify::Core::SampleBuffer.new([1000, -1000, 2000, -2000], format) }

  def build_test_effect
    Class.new(described_class) do
      attr_reader :prepared, :reset_count

      def initialize
        super
        @prepared = []
        @reset_count = 0
      end

      def process_sample(sample, channel:, sample_rate:)
        sample + (channel.zero? ? 2.0 : -2.0) + (sample_rate * 0.0)
      end

      private

      def prepare_runtime_state(sample_rate:, channels:)
        @prepared << [sample_rate, channels]
      end

      def reset_runtime_state
        @reset_count += 1
      end
    end.new
  end

  describe "#apply/#process" do
    it "applies processing and clips to the original format range" do
      effect = build_test_effect

      processed = effect.apply(buffer)

      expect(processed.format).to eq(format)
      expect(processed.samples).to all(be_between(-32_768, 32_767))
      expect(effect.prepared).to eq([[44_100, 2]])
    end

    it "reuses runtime state when sample rate/channel count do not change" do
      effect = build_test_effect

      effect.process(buffer)
      effect.process(buffer)

      expect(effect.prepared.length).to eq(1)
    end

    it "rejects non-sample-buffer input" do
      expect do
        described_class.new.process(:invalid)
      end.to raise_error(Wavify::InvalidParameterError, /buffer must be Core::SampleBuffer/)
    end
  end

  describe "#reset" do
    it "resets runtime information and returns self" do
      effect = build_test_effect
      effect.process(buffer)

      result = effect.reset

      expect(result).to equal(effect)
      expect(effect.reset_count).to be >= 2

      effect.process(buffer)
      expect(effect.prepared.length).to eq(2)
    end
  end

  describe "#process_sample" do
    it "is abstract by default" do
      expect do
        described_class.new.process_sample(0.0, channel: 0, sample_rate: 44_100)
      end.to raise_error(NotImplementedError)
    end
  end
end
