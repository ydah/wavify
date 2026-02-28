# frozen_string_literal: true

RSpec.describe Wavify::DSP::Oscillator do
  let(:mono_float) { Wavify::Core::Format.new(channels: 1, sample_rate: 8_000, bit_depth: 32, sample_format: :float) }

  describe "#generate" do
    it "generates a sine wave buffer" do
      oscillator = described_class.new(waveform: :sine, frequency: 440, amplitude: 1.0)
      buffer = oscillator.generate(0.01, format: mono_float)

      expect(buffer.sample_frame_count).to eq(80)
      expect(buffer.samples.first).to be_within(0.0001).of(0.0)
      expect(buffer.samples.max).to be <= 1.0
      expect(buffer.samples.min).to be >= -1.0
    end

    it "duplicates samples across channels for multichannel format" do
      stereo_float = mono_float.with(channels: 2)
      oscillator = described_class.new(waveform: :square, frequency: 110, amplitude: 0.5)
      buffer = oscillator.generate(0.005, format: stereo_float)

      expect(buffer.format.channels).to eq(2)
      buffer.samples.each_slice(2) do |left, right|
        expect(left).to eq(right)
      end
    end
  end

  describe "#each_sample" do
    it "returns an infinite enumerator of samples" do
      oscillator = described_class.new(waveform: :triangle, frequency: 220, amplitude: 0.8)
      enum = oscillator.each_sample(format: mono_float)
      values = 5.times.map { enum.next }

      expect(values.length).to eq(5)
      expect(values.max).to be <= 0.8
      expect(values.min).to be >= -0.8
    end
  end

  describe "validation" do
    it "raises on unsupported waveform" do
      expect do
        described_class.new(waveform: :pulse, frequency: 440)
      end.to raise_error(Wavify::InvalidParameterError)
    end
  end
end
