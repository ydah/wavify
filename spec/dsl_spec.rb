# frozen_string_literal: true

require "json"
require "tempfile"
require "tmpdir"

RSpec.describe Wavify::DSL do
  let(:format) { Wavify::Core::Format.new(channels: 2, sample_rate: 44_100, bit_depth: 32, sample_format: :float) }

  describe ".build_definition" do
    it "builds a song definition from declarative DSL" do
      song = described_class.build_definition(format: format, tempo: 128) do
        beats_per_bar 4

        track :drums do
          pattern :kick, "x---x---x---x---"
          pattern :snare, "----x-------x---"
          sample :kick, "samples/kick.wav", gain: -3, pan: -0.1, trim: true
          sample :snare, "samples/snare.wav"
          gain(-2)
          pan(-0.1)
        end

        track :lead do
          synth :triangle, detune: 5
          notes "C4 D4 E4 G4", resolution: 8
          envelope attack: 0.01, decay: 0.1, sustain: 0.7, release: 0.2
          effect :chorus, rate: 0.8, depth: 0.4
          gain(-6)
          pan(0.2)
        end

        track :pad do
          synth :sawtooth
          chords %w[Cm7 Fm7 G7 Cm7]
          effect :reverb, room_size: 0.7
        end

        arrange do
          section :intro, bars: 1, tracks: [:pad]
          section :verse, bars: 2, tracks: %i[drums lead pad]
        end
      end

      expect(song).to be_a(Wavify::DSL::SongDefinition)
      expect(song.tempo).to eq(128.0)
      expect(song.tracks.map(&:name)).to eq(%i[drums lead pad])
      expect(song.sections.map(&:name)).to eq(%i[intro verse])

      drums = song.tracks.find { |track| track.name == :drums }
      lead = song.tracks.find { |track| track.name == :lead }

      expect(drums.named_patterns.keys).to eq(%i[kick snare])
      expect(drums.samples[:kick]).to eq("samples/kick.wav")
      expect(drums.sample_options[:kick]).to eq(gain: -3, pan: -0.1, trim: true)
      expect(lead.waveform).to eq(:triangle)
      expect(lead.effects.first[:name]).to eq(:chorus)
      expect(lead.envelope).to be_a(Wavify::DSP::Envelope)
    end
  end

  describe "integration" do
    it "renders and writes audio with Wavify.build" do
      Tempfile.create(["wavify_dsl", ".wav"]) do |file|
        audio = Wavify.build(file.path, format: format, tempo: 120, default_bars: 1) do
          track :lead do
            synth :sine
            notes "C4 E4 G4 C5", resolution: 4
            gain(-9)
          end

          track :pad do
            synth :triangle
            chords ["Cm7"]
            envelope attack: 0.01, decay: 0.02, sustain: 0.8, release: 0.03
            gain(-12)
          end
        end

        expect(audio).to be_a(Wavify::Audio)
        expect(audio.sample_frame_count).to be > 0
        expect(audio.peak_amplitude).to be > 0.0

        loaded = Wavify::Audio.read(file.path)
        expect(loaded.sample_frame_count).to eq(audio.sample_frame_count)
        expect(loaded.format).to eq(format)
      end
    end

    it "can build a timeline from arrangement sections" do
      song = described_class.build_definition(format: format, tempo: 120) do
        track :lead do
          notes "C4 D4 E4 F4"
        end

        track :drums do
          pattern "x---x---"
        end

        arrange do
          section :intro, bars: 1, tracks: [:lead]
          section :verse, bars: 2, tracks: %i[lead drums]
        end
      end

      timeline = song.timeline
      expect(timeline).not_to be_empty
      expect(timeline.any? { |event| event[:track] == :lead && event[:bar] == 2 }).to be(true)
      expect(timeline.any? { |event| event[:track] == :drums && event[:kind] == :trigger }).to be(true)
    end

    it "supports repeated sections, duration, and JSON timeline export" do
      song = described_class.build_definition(format: format, tempo: 120, default_bars: 1) do
        track :lead do
          notes "C4 D4"
        end

        arrange do
          section :loop, bars: 1, tracks: [:lead], repeat: 2
        end
      end

      expect(song.arrangement.map { |section| section[:name] }).to eq(%i[loop loop_2])
      expect(song.duration.total_seconds).to be_within(0.0001).of(4.0)

      parsed = JSON.parse(song.timeline_json)
      expect(parsed).not_to be_empty
      expect(parsed.any? { |event| event["bar"] == 1 }).to be(true)
    end

    it "renders and writes track stems" do
      song = described_class.build_definition(format: format, tempo: 120) do
        track :lead do
          notes "C4 E4"
          gain(-12)
        end

        track :pad do
          chords ["Cm7"]
          gain(-18)
        end
      end

      stems = song.render(stems: true)
      expect(stems.keys).to eq(%i[lead pad])
      expect(stems.values).to all(be_a(Wavify::Audio))
      expect(stems.values.map(&:sample_frame_count)).to all(be > 0)

      Dir.mktmpdir("wavify_stems") do |directory|
        paths = song.write_stems(directory)
        expect(paths.keys).to eq(%i[lead pad])
        expect(paths.values).to all(satisfy { |path| File.exist?(path) })
      end
    end

    it "renders sample-trigger tracks from named patterns" do
      Tempfile.create(["wavify_kick", ".wav"]) do |kick|
        Tempfile.create(["wavify_snare", ".wav"]) do |snare|
          sample_format = Wavify::Core::Format::CD_QUALITY
          Wavify::Audio.tone(frequency: 90, duration: 0.08, waveform: :sine, format: sample_format)
                       .fade_out(0.05)
                       .write(kick.path)
          Wavify::Audio.tone(frequency: 240, duration: 0.05, waveform: :white_noise, format: sample_format)
                       .gain(-8)
                       .fade_out(0.03)
                       .write(snare.path)

          song = described_class.build_definition(format: format, tempo: 120) do
            track :drums do
              pattern :kick, "x---x---x---x---"
              pattern :snare, "----x-------x---"
              sample :kick, kick.path
              sample :snare, snare.path
              effect :compressor, threshold: -20, ratio: 2.0, attack: 0.002, release: 0.04
              gain(-4)
            end
          end

          audio = song.render(default_bars: 1)

          expect(audio).to be_a(Wavify::Audio)
          expect(audio.sample_frame_count).to be > 0
          expect(audio.peak_amplitude).to be > 0.0
        end
      end
    end

    it "applies per-sample track options while rendering" do
      Tempfile.create(["wavify_hit", ".wav"]) do |hit|
        sample_format = format
        source = Wavify::Core::SampleBuffer.new([0.0, 0.0, 0.8, 0.8, 0.4, 0.4], sample_format)
        Wavify::Audio.new(source).write(hit.path)

        song = described_class.build_definition(format: format, tempo: 120) do
          track :drums do
            pattern :hit, "X---"
            sample :hit, hit.path, from: 1.0 / sample_format.sample_rate, duration: 1.0 / sample_format.sample_rate, gain: -6, pan: 1.0
          end
        end

        audio = song.render(default_bars: 1)

        expect(audio.sample_frame_count).to eq(1)
        left, right = audio.buffer.samples.first(2)
        expect(left.abs).to be < 0.001
        expect(right).to be_within(0.01).of(0.8 * (10.0**(-6.0 / 20.0)))
      end
    end
  end
end
