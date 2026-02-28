# frozen_string_literal: true

RSpec.describe "stub codecs" do
  it "reads OGG Vorbis fixture through the provisional decode path" do
    buffer = Wavify::Codecs::OggVorbis.read("spec/fixtures/audio/stereo_vorbis_44100.ogg")

    expect(buffer).to be_a(Wavify::Core::SampleBuffer)
    expect(buffer.sample_frame_count).to be > 0
  end
end
