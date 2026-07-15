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


  describe "short IO helpers" do
    it "continues reading until the requested byte count is available" do
      io = Class.new do
        def initialize(bytes)
          @io = StringIO.new(bytes)
        end

        def read(size)
          @io.read([size, 3].min)
        end
      end.new("abcdefgh")

      expect(described_class.send(:read_exact, io, 8, "short")).to eq("abcdefgh")
    end

    it "bounds individual reads for oversized declared byte counts" do
      io = Class.new do
        def initialize
          @served = false
        end

        def read(size)
          raise RangeError, "read request is too large" if size > 65_536
          return nil if @served

          @served = true
          "abc"
        end
      end.new

      expect do
        described_class.send(:read_exact, io, 0xFFFF_FFFF, "truncated")
      end.to raise_error(Wavify::InvalidFormatError, "truncated")
    end

    it "continues writing until every byte has been accepted" do
      io = Class.new do
        attr_reader :bytes

        def initialize
          @bytes = +"".b
        end

        def write(data)
          accepted = data.byteslice(0, 3)
          @bytes << accepted
          accepted.bytesize
        end
      end.new

      expect(described_class.send(:write_all, io, "abcdefgh")).to eq(8)
      expect(io.bytes).to eq("abcdefgh")
    end
  end
end
