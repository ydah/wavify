# frozen_string_literal: true

RSpec.describe "codec public contract" do
  let(:format) do
    Wavify::Core::Format.new(channels: 1, sample_rate: 8_000, bit_depth: 16, sample_format: :pcm)
  end

  {
    Wavify::Codecs::Wav => "sample.wav",
    Wavify::Codecs::Aiff => "sample.aiff",
    Wavify::Codecs::Flac => "sample.flac",
    Wavify::Codecs::OggVorbis => "sample.ogg",
    Wavify::Codecs::Raw => "sample.raw"
  }.each do |codec, filename|
    context codec.name do
      it "exposes the common class-method protocol" do
        expect([true, false]).to include(codec.available?)
        expect([true, false]).to include(codec.can_read?(filename))
        %i[read write stream_read stream_write metadata].each do |method_name|
          expect(codec).to respond_to(method_name)
        end
      end

      it "returns enumerators for deferred stream operations" do
        skip "optional native codec unavailable" if codec.respond_to?(:available?) && !codec.available?

        read_keywords = codec == Wavify::Codecs::Raw ? { format: format } : {}
        expect(codec.stream_read(filename, **read_keywords)).to be_an(Enumerator)
        expect(codec.stream_write(filename, format: format)).to be_an(Enumerator)
      end
    end
  end
end
