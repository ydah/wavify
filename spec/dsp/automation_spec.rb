# frozen_string_literal: true

RSpec.describe Wavify::DSP::Automation do
  let(:format) { Wavify::Core::Format.new(channels: 1, sample_rate: 8_000, bit_depth: 32, sample_format: :float) }

  it "interpolates between automation points" do
    automation = described_class.new([{ time: 0.0, value: 0.0 }, { time: 1.0, value: 10.0 }])

    expect(automation.value_at(0.0)).to eq(0.0)
    expect(automation.value_at(0.5)).to eq(5.0)
    expect(automation.value_at(2.0)).to eq(10.0)
  end

  it "applies time-varying gain to sample buffers" do
    automation = described_class.new([{ time: 0.0, value: 0.0 }, { time: 3.0 / 8_000, value: -6.0206 }])
    buffer = Wavify::Core::SampleBuffer.new([1.0, 1.0, 1.0, 1.0], format)

    processed = automation.apply_gain(buffer)

    expect(processed.samples.first).to be_within(0.0001).of(1.0)
    expect(processed.samples.last).to be < 1.0
  end

  it "applies gain to PCM through a normalized float workspace" do
    pcm_format = Wavify::Core::Format.new(channels: 1, sample_rate: 8_000, bit_depth: 16, sample_format: :pcm)
    buffer = Wavify::Core::SampleBuffer.new([1_000, -1_000], pcm_format)
    automation = described_class.new([[0.0, 0.0]])

    processed = automation.apply_gain(buffer)

    expect(processed.samples).to eq([1_000, -1_000])
  end

  it "exposes immutable points" do
    automation = described_class.new([[0.0, 1.0]])

    expect(automation.points.first).to be_frozen
    expect { automation.points.first.time = 2.0 }.to raise_error(FrozenError)
  end

  it "supports custom automated transforms" do
    automation = described_class.new([[0.0, 0.0], [1.0 / 8_000, 1.0]])
    buffer = Wavify::Core::SampleBuffer.new([1.0, 1.0], format)

    processed = automation.apply(buffer) { |sample, value, _time, _channel| sample * value }

    expect(processed.samples).to eq([0.0, 1.0])
  end

  it "scans automation points once per frame and reuses values across channels" do
    stereo_format = format.with(channels: 2)
    points = Array.new(1_000) { |index| [index.to_f / 8_000, index.to_f] }
    automation = described_class.new(points)
    buffer = Wavify::Core::SampleBuffer.new(Array.new(2_000, 1.0), stereo_format)
    frame_values = Hash.new { |hash, key| hash[key] = [] }

    expect(automation).not_to receive(:value_at)
    automation.apply(buffer) do |sample, value, time, _channel|
      frame_values[time] << value
      sample
    end

    expect(frame_values.values).to all(satisfy { |values| values.length == 2 && values.uniq.length == 1 })
  end

  it "rejects invalid point sets" do
    expect { described_class.new([]) }.to raise_error(Wavify::InvalidParameterError)
    expect { described_class.new([{ time: -1.0, value: 0.0 }]) }.to raise_error(Wavify::InvalidParameterError)
  end
end
