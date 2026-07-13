# frozen_string_literal: true

RSpec.describe Wavify do
  it "has a version number" do
    expect(Wavify::VERSION).not_to be nil
  end

  it "defines the base error type" do
    expect(Wavify::Error).to be < StandardError
  end

  it "keeps general parameter errors outside the DSP hierarchy" do
    expect(Wavify::InvalidParameterError).to be < Wavify::Error
    expect(Wavify::InvalidParameterError).not_to be < Wavify::DSPError
  end

  it "builds duration helper values without monkey-patching Numeric" do
    expect(described_class.seconds(2).total_seconds).to eq(2.0)
    expect(described_class.ms(250).total_seconds).to eq(0.25)
  end

  it "catalogs optional adapters without loading mandatory dependencies" do
    expect(described_class::Adapters.known.map(&:name)).to include(:ffmpeg, :mp3, :midi, :spectrogram)
    expect(described_class::Adapters.find(:ffmpeg).gem_name).to eq("wavify-ffmpeg")

    expect do
      described_class::Adapters.load(:ffmpeg)
    end.to raise_error(Wavify::UnsupportedFormatError, /wavify-ffmpeg/)
  end
end
