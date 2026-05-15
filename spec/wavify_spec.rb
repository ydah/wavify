# frozen_string_literal: true

RSpec.describe Wavify do
  it "has a version number" do
    expect(Wavify::VERSION).not_to be nil
  end

  it "defines the base error type" do
    expect(Wavify::Error).to be < StandardError
  end

  it "builds duration helper values without monkey-patching Numeric" do
    expect(described_class.seconds(2).total_seconds).to eq(2.0)
    expect(described_class.ms(250).total_seconds).to eq(0.25)
  end
end
