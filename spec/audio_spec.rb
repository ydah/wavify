# frozen_string_literal: true

require "stringio"
require "tempfile"

RSpec.describe Wavify::Audio do
  let(:format) { Wavify::Core::Format.new(channels: 2, sample_rate: 44_100, bit_depth: 16, sample_format: :pcm) }

  describe ".silence" do
    it "builds silent audio for the requested duration" do
      audio = described_class.silence(0.5, format: format)

      expect(audio.sample_frame_count).to eq(22_050)
      expect(audio.buffer.samples.uniq).to eq([0])
    end

    it "accepts a Duration without Numeric monkey patches" do
      audio = described_class.silence(Wavify.ms(250), format: format)

      expect(audio.sample_frame_count).to eq(11_025)
    end
  end

  describe "read/write" do
    it "writes and reads wav files through registry" do
      source_buffer = Wavify::Core::SampleBuffer.new([100, -100, 200, -200], format)
      source_audio = described_class.new(source_buffer)

      Tempfile.create(["wavify_audio", ".wav"]) do |file|
        source_audio.write(file.path)
        loaded = described_class.read(file.path)

        expect(loaded.format).to eq(format)
        expect(loaded.buffer.samples).to eq(source_buffer.samples)
      end
    end

    it "writes generic IO using an explicit codec or filename hint" do
      audio = described_class.new(Wavify::Core::SampleBuffer.new([0.1, 0.1], format))
      explicit = StringIO.new(+"".b)
      hinted = StringIO.new(+"".b)

      audio.write(explicit, codec: :wav)
      audio.write(hinted, filename: "output.wav")

      expect(explicit.string).to start_with("RIFF")
      expect(hinted.string).to start_with("RIFF")
    end

    it "reads OGG Vorbis through the registry", :ogg do
      audio = described_class.read("spec/fixtures/audio/stereo_vorbis_44100.ogg")

      expect(audio).to be_a(described_class)
      expect(audio.format.channels).to eq(2)
      expect(audio.format.sample_rate).to eq(44_100)
      expect(audio.sample_frame_count).to be > 0
      expect(audio.buffer.samples.any? { |sample| sample != 0.0 }).to eq(true)
    end

    it "passes codec-specific write options through registry" do
      source_buffer = Wavify::Core::SampleBuffer.new([100, -100, 200, -200, 300, -300, 400, -400], format)
      source_audio = described_class.new(source_buffer)

      Tempfile.create(["wavify_audio", ".flac"]) do |file|
        source_audio.write(file.path, codec_options: { block_size: 2 })

        metadata = Wavify::Codecs::Flac.metadata(file.path)
        loaded = described_class.read(file.path)

        expect(metadata[:min_block_size]).to eq(2)
        expect(metadata[:max_block_size]).to eq(2)
        expect(loaded.buffer.samples).to eq(source_buffer.samples)
      end
    end

    it "passes WAV info metadata write options through registry" do
      source_buffer = Wavify::Core::SampleBuffer.new([100, -100], format.with(channels: 1))
      source_audio = described_class.new(source_buffer)

      Tempfile.create(["wavify_audio_info", ".wav"]) do |file|
        source_audio.write(file.path, codec_options: { info: { title: "Tone", software: "wavify-spec" } })

        metadata = described_class.metadata(file.path)
        expect(metadata[:info][:title]).to eq("Tone")
        expect(metadata[:info][:software]).to eq("wavify-spec")
      end
    end

    it "reads metadata through the registry without constructing Audio" do
      source_buffer = Wavify::Core::SampleBuffer.new([100, -100, 200, -200], format)

      Tempfile.create(["wavify_audio", ".wav"]) do |file|
        Wavify::Codecs::Wav.write(file.path, source_buffer)

        metadata = described_class.metadata(file.path)

        expect(metadata[:format]).to eq(format)
        expect(metadata[:sample_frame_count]).to eq(2)
        expect(described_class.info(file.path)).to eq(metadata)
      end
    end

    it "projects encoded metadata into an explicitly requested format" do
      source_buffer = Wavify::Core::SampleBuffer.new([100, -100, 200, -200], format)
      projected_format = format.with(channels: 1, sample_rate: 48_000, bit_depth: 24)

      Tempfile.create(["wavify_audio", ".wav"]) do |file|
        Wavify::Codecs::Wav.write(file.path, source_buffer)

        metadata = described_class.metadata(file.path, format: projected_format)

        expect(metadata[:format]).to eq(projected_format)
        expect(metadata[:sample_frame_count]).to eq(2)
        expect(metadata[:duration].total_seconds).to be_within(1.0 / 48_000).of(2.0 / 44_100)
      end
    end

    it "projects sample-coordinate metadata with the decoded frame count" do
      source_format = format.with(channels: 1, sample_rate: 44_100)
      target_format = source_format.with(sample_rate: 48_000)
      codec = Class.new do
        class << self
          attr_accessor :metadata_result

          def metadata(_path)
            metadata_result
          end
        end
      end
      codec.metadata_result = {
        format: source_format,
        sample_frame_count: 442,
        duration: Wavify::Core::Duration.from_samples(442, source_format.sample_rate),
        fact_sample_length: 442,
        loops: [{ start_frame: 110, end_frame: 220, length_frames: 111 }],
        smpl: { sample_period: 22_676, loops: [{ start_frame: 110, end_frame: 220 }] },
        cue_points: [{ position: 110, sample_offset: 220 }],
        cue: { cue_count: 1, points: [{ position: 110, sample_offset: 220 }] }
      }
      allow(Wavify::Codecs::Registry).to receive(:detect_for_read).and_return(codec)
      decoded_frames = Wavify::Core::SampleBuffer.new(Array.new(442, 0), source_format)
                                                 .convert(target_format).sample_frame_count

      metadata = described_class.metadata("projected.wav", format: target_format)

      expect(metadata[:sample_frame_count]).to eq(decoded_frames)
      expect(metadata[:fact_sample_length]).to eq(decoded_frames)
      expect(metadata[:loops].first).to include(start_frame: 120, end_frame: 239, length_frames: 120)
      expect(metadata[:cue_points].first).to include(position: 120, sample_offset: 239)
      expect(metadata.dig(:smpl, :loops, 0)).to include(start_frame: 120, end_frame: 239)
      expect(metadata.dig(:cue, :points)).to eq(metadata[:cue_points])
    end

    it "passes explicit format for raw metadata" do
      raw_format = format.with(channels: 1)
      source_buffer = Wavify::Core::SampleBuffer.new([100, -100], raw_format)

      Tempfile.create(["wavify_audio", ".raw"]) do |file|
        Wavify::Codecs::Raw.write(file.path, source_buffer, format: raw_format)

        metadata = described_class.metadata(file.path, format: raw_format)

        expect(metadata[:format]).to eq(raw_format)
        expect(metadata[:sample_frame_count]).to eq(2)
      end
    end

    it "detects extension and magic mismatches in strict read mode" do
      Tempfile.create(["wavify_audio", ".flac"]) do |file|
        file.binmode
        file.write("RIFF\x24\x00\x00\x00WAVE")
        file.flush

        expect do
          described_class.read(file.path, strict: true)
        end.to raise_error(Wavify::InvalidFormatError, /codec mismatch/)
      end
    end

    it "reads raw IO using a filename hint and explicit format" do
      raw_format = format.with(channels: 1)
      source_buffer = Wavify::Core::SampleBuffer.new([100, -100, 200], raw_format)
      io = StringIO.new
      Wavify::Codecs::Raw.write(io, source_buffer, format: raw_format)

      loaded = described_class.read(io, filename: "clip.raw", format: raw_format)

      expect(loaded.buffer.samples).to eq(source_buffer.samples)
      expect(loaded.format).to eq(raw_format)
    end

    it "refuses to overwrite existing path output when requested" do
      source_audio = described_class.silence(0.001, format: format)

      Tempfile.create(["wavify_audio_existing", ".wav"]) do |file|
        expect(File).not_to receive(:exist?)
        expect do
          source_audio.write(file.path, overwrite: false)
        end.to raise_error(Wavify::InvalidParameterError, /already exists/)
      end
    end

    it "creates a new output atomically when overwrite is disabled" do
      source_audio = described_class.silence(0.001, format: format)

      Dir.mktmpdir do |dir|
        path = File.join(dir, "exclusive.wav")

        expect(source_audio.write(path, overwrite: false)).to equal(source_audio)
        expect(described_class.read(path)).to eq(source_audio)
      end
    end
  end

  describe ".stream" do
    it "builds a Core::Stream for chunk processing" do
      source_buffer = Wavify::Core::SampleBuffer.new([100, -100, 200, -200], format)

      Tempfile.create(["wavify_audio_stream", ".wav"]) do |file|
        Wavify::Codecs::Wav.write(file.path, source_buffer)

        stream = described_class.stream(file.path, chunk_size: 1)
        expect(stream).to be_a(Wavify::Core::Stream)
        expect(stream.each_chunk.map(&:sample_frame_count)).to eq([1, 1])
      end
    end

    it "streams OGG Vorbis through Core::Stream", :ogg do
      metadata = Wavify::Codecs::OggVorbis.metadata("spec/fixtures/audio/stereo_vorbis_44100.ogg")
      stream = described_class.stream(
        "spec/fixtures/audio/stereo_vorbis_44100.ogg",
        chunk_size: 256
      )

      chunks = stream.each_chunk.to_a
      expect(chunks).not_to be_empty
      expect(chunks).to all(be_a(Wavify::Core::SampleBuffer))
      expect(chunks.sum(&:sample_frame_count)).to eq(metadata[:sample_frame_count])
    end

    it "streams raw IO using a filename hint and explicit format" do
      raw_format = format.with(channels: 1)
      source_buffer = Wavify::Core::SampleBuffer.new([100, -100, 200, -200], raw_format)
      io = StringIO.new
      Wavify::Codecs::Raw.write(io, source_buffer, format: raw_format)

      stream = described_class.stream(io, filename: "clip.raw", format: raw_format, chunk_size: 2)

      expect(stream.each_chunk.flat_map(&:samples)).to eq(source_buffer.samples)
    end
  end

  describe ".mix" do
    it "mixes multiple audios and clips summed amplitude" do
      a = described_class.new(Wavify::Core::SampleBuffer.new([0.4, 0.4, 0.4, 0.4], format.with(sample_format: :float, bit_depth: 32)))
      b = described_class.new(Wavify::Core::SampleBuffer.new([0.8, 0.8, -0.8, -0.8], format.with(sample_format: :float, bit_depth: 32)))

      mixed = described_class.mix(a, b)

      expect(mixed.sample_frame_count).to eq(2)
      expect(mixed.buffer.samples[0]).to be_within(0.0001).of(1.0)
      expect(mixed.buffer.samples[2]).to be_within(0.0001).of(-0.4)
    end

    it "can normalize instead of clipping when mixing" do
      a = described_class.new(Wavify::Core::SampleBuffer.new([0.75, -0.75], format.with(channels: 1, sample_format: :float, bit_depth: 32)))
      b = described_class.new(Wavify::Core::SampleBuffer.new([0.75, 0.0], format.with(channels: 1, sample_format: :float, bit_depth: 32)))

      mixed = described_class.mix(a, b, strategy: :normalize)

      expect(mixed.buffer.samples[0]).to be_within(0.0001).of(1.0)
      expect(mixed.buffer.samples[1]).to be_within(0.0001).of(-0.5)
    end

    it "can apply headroom when mixing" do
      a = described_class.new(Wavify::Core::SampleBuffer.new([0.75], format.with(channels: 1, sample_format: :float, bit_depth: 32)))
      b = described_class.new(Wavify::Core::SampleBuffer.new([0.75], format.with(channels: 1, sample_format: :float, bit_depth: 32)))

      mixed = described_class.mix(a, b, strategy: :headroom)

      expect(mixed.buffer.samples[0]).to be_within(0.0001).of(1.0)
    end

    it "applies headroom only near source overlaps" do
      mono_format = format.with(channels: 1, sample_rate: 8_000, sample_format: :float, bit_depth: 32)
      long = described_class.new(Wavify::Core::SampleBuffer.new(Array.new(100, 1.0), mono_format))
      short = described_class.new(Wavify::Core::SampleBuffer.new(Array.new(2, 1.0), mono_format))

      mixed = described_class.mix(long, short, strategy: :headroom, align: :end)

      expect(mixed.buffer.samples.first(50)).to all(eq(1.0))
      expect(mixed.buffer.samples.last(2)).to all(eq(1.0))
    end

    it "does not attenuate low-amplitude overlaps" do
      mono_format = format.with(channels: 1, sample_rate: 8_000, sample_format: :float, bit_depth: 32)
      bed = described_class.new(Wavify::Core::SampleBuffer.new(Array.new(160, 0.8), mono_format))
      clip = described_class.new(Wavify::Core::SampleBuffer.new(Array.new(32, 0.1), mono_format))

      mixed = bed.overlay(clip, at: 0.008, strategy: :headroom)

      expect(mixed.buffer.samples.first(64)).to all(eq(0.8))
      expect(mixed.buffer.samples.slice(64, 32)).to all(be_within(0.0001).of(0.9))
    end

    it "allows callers to control anticipatory headroom smoothing" do
      mono_format = format.with(channels: 1, sample_rate: 8_000, sample_format: :float, bit_depth: 32)
      bed = described_class.new(Wavify::Core::SampleBuffer.new(Array.new(160, 0.8), mono_format))
      clip = described_class.new(Wavify::Core::SampleBuffer.new(Array.new(32, 0.4), mono_format))

      smoothed = bed.overlay(clip, at: 0.008, strategy: :headroom)
      immediate = bed.overlay(clip, at: 0.008, strategy: :headroom, headroom_smoothing: 0.0)

      expect(smoothed.buffer.samples[63]).to be < 0.8
      expect(immediate.buffer.samples[63]).to eq(0.8)
      expect(smoothed.peak_amplitude).to be <= 1.0
      expect(immediate.peak_amplitude).to be <= 1.0
    end

    it "rejects invalid headroom smoothing" do
      audio = described_class.new(Wavify::Core::SampleBuffer.new([0.5], format.with(channels: 1)))

      expect do
        described_class.mix(audio, strategy: :headroom, headroom_smoothing: -0.1)
      end.to raise_error(Wavify::InvalidParameterError, /smoothing/)
    end

    it "can soft-limit mix peaks" do
      a = described_class.new(Wavify::Core::SampleBuffer.new([0.9], format.with(channels: 1, sample_format: :float, bit_depth: 32)))
      b = described_class.new(Wavify::Core::SampleBuffer.new([0.9], format.with(channels: 1, sample_format: :float, bit_depth: 32)))

      mixed = described_class.mix(a, b, strategy: :soft_limit)

      expect(mixed.buffer.samples[0]).to be > 0.9
      expect(mixed.buffer.samples[0]).to be <= 1.0
    end

    it "applies per-source gains and alignment" do
      mono_format = format.with(channels: 1, sample_format: :float, bit_depth: 32)
      a = described_class.new(Wavify::Core::SampleBuffer.new([0.5, 0.5], mono_format))
      b = described_class.new(Wavify::Core::SampleBuffer.new([0.5], mono_format))

      mixed = described_class.mix(a, b, gains: [0.0, -6.0206], align: :end)

      expect(mixed.buffer.samples[0]).to be_within(0.0001).of(0.5)
      expect(mixed.buffer.samples[1]).to be_within(0.0001).of(0.75)
    end

    it "rejects unsupported mix strategies" do
      audio = described_class.new(Wavify::Core::SampleBuffer.new([0.1], format.with(channels: 1, sample_format: :float, bit_depth: 32)))

      expect do
        described_class.mix(audio, strategy: :unknown)
      end.to raise_error(Wavify::InvalidParameterError, /strategy/)
    end

    it "rejects invalid mix gains and alignment" do
      audio = described_class.new(Wavify::Core::SampleBuffer.new([0.1], format.with(channels: 1, sample_format: :float, bit_depth: 32)))

      expect do
        described_class.mix(audio, gains: [0.0, 1.0])
      end.to raise_error(Wavify::InvalidParameterError, /one value per Audio/)

      expect do
        described_class.mix(audio, align: :unknown)
      end.to raise_error(Wavify::InvalidParameterError, /align/)
    end

    it "raises when sample rates differ" do
      f1 = Wavify::Core::Format.new(channels: 1, sample_rate: 44_100, bit_depth: 32, sample_format: :float)
      f2 = Wavify::Core::Format.new(channels: 1, sample_rate: 48_000, bit_depth: 32, sample_format: :float)
      a = described_class.new(Wavify::Core::SampleBuffer.new([0.1, 0.2], f1))
      b = described_class.new(Wavify::Core::SampleBuffer.new([0.1, 0.2], f2))

      expect do
        described_class.mix(a, b)
      end.to raise_error(Wavify::InvalidParameterError)
    end
  end

  describe "#normalize" do
    it "normalizes by peak amplitude by default" do
      source = described_class.new(Wavify::Core::SampleBuffer.new([0.25, -0.5], format.with(channels: 1, sample_format: :float, bit_depth: 32)))

      normalized = source.normalize(target_db: -6.0206)

      expect(normalized.peak_amplitude).to be_within(0.0001).of(0.5)
    end

    it "normalizes by RMS amplitude when requested" do
      source = described_class.new(Wavify::Core::SampleBuffer.new([0.5, 0.0, -0.5, 0.0], format.with(channels: 1, sample_format: :float, bit_depth: 32)))

      normalized = source.normalize(target_db: -6.0206, mode: :rms)

      expect(normalized.rms_amplitude).to be_within(0.0001).of(0.5)
      expect(normalized.peak_amplitude).to be < 1.0
    end

    it "normalizes by BS.1770 integrated LUFS when requested" do
      source = described_class.new(Wavify::Core::SampleBuffer.new([0.25, -0.25, 0.25, -0.25], format.with(channels: 1, sample_format: :float, bit_depth: 32)))

      normalized = source.normalize(target_db: -12.0, mode: :lufs)

      expect(normalized.lufs).to be_within(0.001).of(-12.0)
      expect(normalized.stats[:lufs]).to be_within(0.001).of(-12.0)
    end

    it "rejects unsupported normalization modes" do
      source = described_class.new(Wavify::Core::SampleBuffer.new([0.1], format.with(channels: 1, sample_format: :float, bit_depth: 32)))

      expect do
        source.normalize(mode: :bogus)
      end.to raise_error(Wavify::InvalidParameterError, /mode/)
    end
  end

  describe "#convert" do
    it "returns a new audio with converted format" do
      source = described_class.new(Wavify::Core::SampleBuffer.new([100, -100], format.with(channels: 1)))
      target_format = Wavify::Core::Format.new(channels: 1, sample_rate: 48_000, bit_depth: 32, sample_format: :float)

      converted = source.convert(target_format)

      expect(converted).not_to equal(source)
      expect(converted.format).to eq(target_format)
    end

    it "offers shortcut format conversions and direct format readers" do
      source = described_class.new(Wavify::Core::SampleBuffer.new([100, -100], format.with(channels: 1)))

      expect(source.channels).to eq(1)
      expect(source.sample_rate).to eq(44_100)
      expect(source.bit_depth).to eq(16)
      expect(source.to_stereo.channels).to eq(2)
      expect(source.resample(sample_rate: 48_000).sample_rate).to eq(48_000)
      expect(source.with_bit_depth(24).bit_depth).to eq(24)
    end

    it "passes dither options through shortcut bit-depth conversion" do
      pcm_format = format.with(channels: 1, bit_depth: 16)
      source = described_class.new(Wavify::Core::SampleBuffer.new(Array.new(32, 0), pcm_format))

      converted = source.with_bit_depth(8, dither: true, dither_seed: 7)

      expect(converted.bit_depth).to eq(8)
      expect(converted.buffer.samples.uniq).not_to eq([0])
    end

    it "provides an explicit bit-depth conversion alias" do
      source = described_class.silence(0.001, format: format)

      expect(source.with_bit_depth(24).format.bit_depth).to eq(24)
    end
  end

  describe "#split" do
    it "splits audio at a time offset in seconds" do
      source = described_class.new(
        Wavify::Core::SampleBuffer.new([1, -1, 2, -2, 3, -3, 4, -4], format)
      )
      left, right = source.split(at: (1.0 / 44_100))

      expect(left.sample_frame_count).to eq(1)
      expect(right.sample_frame_count).to eq(3)
      expect(left.buffer.samples).to eq([1, -1])
      expect(right.buffer.samples).to eq([2, -2, 3, -3, 4, -4])
    end

    it "slices and crops by time" do
      source = described_class.new(
        Wavify::Core::SampleBuffer.new([1, -1, 2, -2, 3, -3, 4, -4], format)
      )

      sliced = source.slice(from: (1.0 / 44_100), to: (3.0 / 44_100))
      cropped = source.crop(start: (2.0 / 44_100), duration: (10.0 / 44_100))

      expect(sliced.buffer.samples).to eq([2, -2, 3, -3])
      expect(cropped.buffer.samples).to eq([3, -3, 4, -4])
    end
  end

  describe "timeline editing" do
    it "concats, prepends, and pads audio" do
      a = described_class.new(Wavify::Core::SampleBuffer.new([1, -1], format))
      b = described_class.new(Wavify::Core::SampleBuffer.new([2, -2], format))

      expect(a.concat(b).buffer.samples).to eq([1, -1, 2, -2])
      expect(a.prepend(b).buffer.samples).to eq([2, -2, 1, -1])
      expect(a.pad_start(1.0 / 44_100).buffer.samples).to eq([0, 0, 1, -1])
      expect(a.pad_end(1.0 / 44_100).buffer.samples).to eq([1, -1, 0, 0])
    end

    it "inserts silence and overlays clips" do
      source = described_class.new(Wavify::Core::SampleBuffer.new([100, -100, 200, -200], format))
      other = described_class.new(Wavify::Core::SampleBuffer.new([50, 50], format))

      inserted = source.insert_silence(at: (1.0 / 44_100), duration: (1.0 / 44_100))
      overlayed = source.overlay(other, at: (1.0 / 44_100))

      expect(inserted.buffer.samples).to eq([100, -100, 0, 0, 200, -200])
      expect(overlayed.buffer.samples).to eq([100, -100, 250, -150])
    end

    it "crossfades between clips" do
      float_format = format.with(channels: 1, sample_format: :float, bit_depth: 32)
      left = described_class.new(Wavify::Core::SampleBuffer.new([1.0, 1.0, 1.0, 1.0], float_format))
      right = described_class.new(Wavify::Core::SampleBuffer.new([-1.0, -1.0, -1.0, -1.0], float_format))

      faded = left.crossfade(right, duration: 2.0 / 44_100)

      expect(faded.sample_frame_count).to eq(6)
      expect(faded.buffer.samples.first).to eq(1.0)
      expect(faded.buffer.samples.last).to eq(-1.0)
    end
  end

  describe "#repeat" do
    it "repeats audio content the requested number of times" do
      source = described_class.new(Wavify::Core::SampleBuffer.new([10, -10, 20, -20], format))
      repeated = source.repeat(times: 3)

      expect(repeated.sample_frame_count).to eq(6)
      expect(repeated.buffer.samples).to eq([10, -10, 20, -20] * 3)
      expect(source.buffer.samples).to eq([10, -10, 20, -20])
    end
  end


  describe "value equality" do
    it "compares audio by format and samples" do
      first = described_class.silence(0.001, format: format)
      second = described_class.silence(0.001, format: format)

      expect(first).to eq(second)
      expect({ first => :audio }[second]).to eq(:audio)
    end
  end
end
