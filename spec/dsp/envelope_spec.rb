# frozen_string_literal: true

RSpec.describe Wavify::DSP::Envelope do
  let(:envelope) do
    described_class.new(
      attack: 0.1,
      decay: 0.2,
      sustain: 0.5,
      release: 0.3
    )
  end

  describe "#gain_at" do
    it "returns attack gain ramp" do
      expect(envelope.gain_at(0.05, note_on_duration: 0.5)).to be_within(0.001).of(0.5)
    end

    it "returns decay gain ramp" do
      expect(envelope.gain_at(0.2, note_on_duration: 0.5)).to be_within(0.001).of(0.75)
    end

    it "returns sustain level while note is held" do
      expect(envelope.gain_at(0.4, note_on_duration: 0.6)).to be_within(0.001).of(0.5)
    end

    it "returns release ramp after note off" do
      expect(envelope.gain_at(0.75, note_on_duration: 0.6)).to be_within(0.001).of(0.25)
      expect(envelope.gain_at(1.0, note_on_duration: 0.6)).to be_within(0.001).of(0.0)
    end
  end

  describe "#apply" do
    it "applies envelope gain to all channels" do
      format = Wavify::Core::Format.new(channels: 2, sample_rate: 8_000, bit_depth: 32, sample_format: :float)
      buffer = Wavify::Core::SampleBuffer.new([1.0, -1.0, 1.0, -1.0, 1.0, -1.0], format)
      env = described_class.new(attack: 1.0 / 8000, decay: 0.0, sustain: 0.5, release: 1.0 / 8000)

      processed = env.apply(buffer, note_on_duration: 2.0 / 8000)
      # frame 0: t=0.0 => gain 0.0
      # frame 1: t=1/8000 => sustain 0.5 (attack done)
      # frame 2: t=2/8000 => start release, gain 0.5
      expect(processed.samples[0]).to be_within(0.001).of(0.0)
      expect(processed.samples[2]).to be_within(0.001).of(0.5)
      expect(processed.samples[4]).to be_within(0.001).of(0.5)
    end

    it "handles note_on_duration shorter than attack+decay" do
      format = Wavify::Core::Format.new(channels: 1, sample_rate: 8_000, bit_depth: 32, sample_format: :float)
      buffer = Wavify::Core::SampleBuffer.new([1.0] * 80, format)
      processed = envelope.apply(buffer, note_on_duration: 0.001)

      expect(processed.samples.last).to be <= 0.5
    end
  end
end
