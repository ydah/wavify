# frozen_string_literal: true

RSpec.describe Wavify::Codecs::Base do
  describe "abstract interface" do
    it "raises NotImplementedError for all class methods" do
      aggregate_failures do
        expect { described_class.can_read?("x") }.to raise_error(NotImplementedError)
        expect { described_class.read("x") }.to raise_error(NotImplementedError)
        expect { described_class.write("x", nil, format: nil) }.to raise_error(NotImplementedError)
        expect { described_class.stream_read("x") }.to raise_error(NotImplementedError)
        expect { described_class.stream_write("x", format: nil) }.to raise_error(NotImplementedError)
        expect { described_class.metadata("x") }.to raise_error(NotImplementedError)
      end
    end
  end
end
