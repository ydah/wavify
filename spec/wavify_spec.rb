# frozen_string_literal: true

RSpec.describe Wavify do
  it "has a version number" do
    expect(Wavify::VERSION).not_to be nil
  end

  it "defines the base error type" do
    expect(Wavify::Error).to be < StandardError
  end
end
