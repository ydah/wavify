# frozen_string_literal: true

RSpec.describe Wavify::DSP::LoudnessMeter do
  let(:sample_rate) { 48_000 }

  def sine_samples(frequency:, seconds:, channels:, amplitude: 1.0)
    frame_count = (seconds * sample_rate).round
    Array.new(frame_count * channels) do |index|
      frame = index / channels
      amplitude * Math.sin(2.0 * Math::PI * frequency * frame / sample_rate)
    end
  end

  it "matches the BS.1770 reference level for a full-scale mono 1 kHz sine" do
    loudness = described_class.integrated(
      sine_samples(frequency: 1_000, seconds: 1.0, channels: 1),
      sample_rate: sample_rate,
      channels: 1
    )

    expect(loudness).to be_within(0.15).of(-3.05)
  end

  it "applies channel summation for stereo program loudness" do
    loudness = described_class.integrated(
      sine_samples(frequency: 1_000, seconds: 1.0, channels: 2),
      sample_rate: sample_rate,
      channels: 2
    )

    expect(loudness).to be_within(0.15).of(-0.04)
  end

  it "uses relative gating to exclude a quiet tail" do
    loud = sine_samples(frequency: 1_000, seconds: 5.0, channels: 1, amplitude: 0.5)
    quiet = sine_samples(frequency: 1_000, seconds: 5.0, channels: 1, amplitude: 0.0001)

    combined = described_class.integrated(loud + quiet, sample_rate: sample_rate, channels: 1)
    reference = described_class.integrated(loud, sample_rate: sample_rate, channels: 1)

    expect(combined).to be_within(0.2).of(reference)
  end

  it "returns negative infinity for silence" do
    expect(described_class.integrated(Array.new(sample_rate, 0.0), sample_rate: sample_rate, channels: 1)).to eq(-Float::INFINITY)
  end
end
