# frozen_string_literal: true

RSpec.describe Wavify::DSP::LFO do
  it "generates bounded modulation values for supported waveforms" do
    described_class::WAVEFORMS.each do |waveform|
      lfo = described_class.new(rate: 2.0, sample_rate: 100.0, waveform: waveform)
      values = Array.new(100) { lfo.next_value }

      expect(values).to all(be_between(-1.0, 1.0)), waveform.to_s
      expect(values.uniq.length).to be > 1
    end
  end

  it "can reset to its initial phase" do
    lfo = described_class.new(rate: 1.0, sample_rate: 10.0, phase: 0.25)
    first = lfo.next_value
    3.times { lfo.next_value }

    lfo.reset

    expect(lfo.next_value).to eq(first)
  end

  it "rejects invalid parameters" do
    expect { described_class.new(rate: 0.0, sample_rate: 44_100) }.to raise_error(Wavify::InvalidParameterError)
    expect { described_class.new(rate: 1.0, sample_rate: 0) }.to raise_error(Wavify::InvalidParameterError)
    expect { described_class.new(rate: 1.0, sample_rate: 44_100, waveform: :noise) }.to raise_error(Wavify::InvalidParameterError)
  end
end
