# frozen_string_literal: true

RSpec.describe Wavify::DSP::Effects do
  let(:mono_float) { Wavify::Core::Format.new(channels: 1, sample_rate: 44_100, bit_depth: 32, sample_format: :float) }
  let(:stereo_float) { mono_float.with(channels: 2) }

  def impulse_buffer(length:, format: mono_float)
    samples = Array.new(length * format.channels, 0.0)
    samples[0] = 1.0
    Wavify::Core::SampleBuffer.new(samples, format)
  end

  describe Wavify::DSP::Effects::Delay do
    it "produces delayed repeats for an impulse" do
      effect = described_class.new(time: 1.0 / 44_100, feedback: 0.5, mix: 1.0)
      processed = effect.process(impulse_buffer(length: 6))

      expect(processed.samples[0]).to be_within(0.0001).of(0.0)
      expect(processed.samples[1]).to be_within(0.0001).of(1.0)
      expect(processed.samples[2]).to be_within(0.0001).of(0.5)
      expect(processed.samples[3]).to be_within(0.0001).of(0.25)
    end

    it "preserves state across chunked process calls" do
      effect = described_class.new(time: 2.0 / 44_100, feedback: 0.0, mix: 1.0)
      first = Wavify::Core::SampleBuffer.new([1.0, 0.0], mono_float)
      second = Wavify::Core::SampleBuffer.new([0.0, 0.0], mono_float)

      first_out = effect.process(first)
      second_out = effect.process(second)

      expect(first_out.samples).to eq([0.0, 0.0])
      expect(second_out.samples.first).to be_within(0.0001).of(1.0)
    end
  end

  describe Wavify::DSP::Effects::Reverb do
    it "creates a decaying tail from an impulse" do
      effect = described_class.new(room_size: 0.8, damping: 0.4, mix: 1.0)
      processed = effect.process(impulse_buffer(length: 5_000))

      tail = processed.samples[1_000..]
      expect(tail.any? { |sample| sample.abs > 0.0001 }).to be(true)
      expect(processed.samples.length).to eq(5_000)
    end
  end

  describe Wavify::DSP::Effects::Chorus do
    it "modulates a tone while preserving length" do
      effect = described_class.new(rate: 0.8, depth: 0.7, mix: 0.6)
      source = Wavify::Audio.tone(frequency: 440, duration: 0.1, format: stereo_float, waveform: :sine).buffer
      processed = effect.process(source)

      expect(processed.samples.length).to eq(source.samples.length)
      differences = source.samples.zip(processed.samples).map { |left, right| (left - right).abs }
      expect(differences.max).to be > 0.0001
    end
  end

  describe Wavify::DSP::Effects::Distortion do
    it "saturates with tone shaping and mix control" do
      effect = described_class.new(drive: 1.0, tone: 0.2, mix: 1.0)
      source = Wavify::Core::SampleBuffer.new([0.0, 0.2, 0.5, 0.9, -0.9], mono_float)
      processed = effect.process(source)

      expect(processed.samples.max).to be <= 1.0
      expect(processed.samples.min).to be >= -1.0
      expect(processed.samples[3].abs).to be < source.samples[3].abs
    end
  end

  describe Wavify::DSP::Effects::Compressor do
    it "reduces peaks above threshold" do
      effect = described_class.new(threshold: -20.0, ratio: 8.0, attack: 0.0, release: 0.01)
      source = Wavify::Core::SampleBuffer.new([0.05, 0.1, 0.8, 0.8, 0.1, 0.05], mono_float)
      processed = effect.process(source)

      expect(processed.samples[2].abs).to be < source.samples[2].abs
      expect(processed.samples[0]).to be_within(0.01).of(source.samples[0])
    end
  end

  it "exposes effects under Wavify::Effects alias" do
    expect(Wavify::Effects::Delay).to eq(Wavify::DSP::Effects::Delay)
  end
end
