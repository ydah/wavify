# frozen_string_literal: true

RSpec.describe "codec parser properties" do
  let(:format) do
    Wavify::Core::Format.new(channels: 1, sample_rate: 8_000, bit_depth: 16, sample_format: :pcm)
  end
  let(:buffer) do
    Wavify::Core::SampleBuffer.new([0, 1_000, -1_000, 2_000, -2_000, 0], format)
  end

  def encoded_bytes(codec, buffer, format)
    io = StringIO.new("".b)
    codec.write(io, buffer, format: format)
    io.string
  end

  def malformed_variants(bytes, seed:)
    rng = Random.new(seed)
    variants = ["".b, bytes.byteslice(0, 1), bytes.byteslice(0, bytes.bytesize / 2)]
    24.times do
      mutated = bytes.dup
      mutation_count = rng.rand(1..4)
      mutation_count.times do
        index = rng.rand(0...mutated.bytesize)
        mutated.setbyte(index, rng.rand(0..255))
      end
      variants << mutated

      next if bytes.bytesize < 2

      start = rng.rand(0...bytes.bytesize)
      length = rng.rand(1..[8, bytes.bytesize - start].max)
      variants << (bytes.byteslice(0, start).to_s + bytes.byteslice(start + length, bytes.bytesize).to_s)
    end
    variants << (bytes + "\xFF\xFE\xFAtrailing".b)
    variants.uniq
  end

  def expect_controlled_parser_result(codec, bytes, operation)
    codec.public_send(operation, StringIO.new(bytes))
  rescue Wavify::Error
    nil
  rescue StandardError => e
    raise RSpec::Expectations::ExpectationNotMetError,
          "#{codec}.#{operation} leaked #{e.class} for #{bytes.bytesize} bytes: #{e.message}"
  end

  {
    Wavify::Codecs::Wav => 11,
    Wavify::Codecs::Aiff => 22,
    Wavify::Codecs::Flac => 33
  }.each do |codec, seed|
    it "keeps randomized #{codec.name.split('::').last} corruption inside the public error contract" do
      bytes = encoded_bytes(codec, buffer, format)

      malformed_variants(bytes, seed: seed).each do |variant|
        expect_controlled_parser_result(codec, variant, :metadata)
        expect_controlled_parser_result(codec, variant, :read)
      end
    end
  end

  it "keeps randomized OGG corruption inside the public error contract", :ogg do
    bytes = File.binread("spec/fixtures/audio/stereo_vorbis_44100.ogg")

    malformed_variants(bytes, seed: 44).first(30).each do |variant|
      expect_controlled_parser_result(Wavify::Codecs::OggVorbis, variant, :metadata)
      expect_controlled_parser_result(Wavify::Codecs::OggVorbis, variant, :read)
    end
  end
end
