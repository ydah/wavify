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
        swing 0.58

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
      expect(song.swing).to eq(0.58)
      expect(song.tracks.map(&:name)).to eq(%i[drums lead pad])
      expect(song.sections.map(&:name)).to eq(%i[intro verse])

      drums = song.tracks.find { |track| track.name == :drums }
      lead = song.tracks.find { |track| track.name == :lead }

      expect(drums.named_patterns.keys).to eq(%i[kick snare])
      expect(drums.samples[:kick]).to eq("samples/kick.wav")
      expect(drums.sample_options[:kick]).to eq(gain: -3, pan: -0.1, trim: true)
      expect(lead.waveform).to eq(:triangle)
      expect(lead.synth_options).to eq(detune: 5)
      expect(lead.effects.first[:name]).to eq(:chorus)
      expect(lead.envelope).to be_a(Wavify::DSP::Envelope)
    end

    it "resolves samples from a configured sample folder" do
      song = described_class.build_definition(format: format, tempo: 120) do
        sample_folder "samples"

        track :drums do
          pattern :kick, "x---"
          pattern :snare, "----"
          sample :kick
          sample :snare, "drums/snare.wav"
        end
      end

      drums = song.tracks.fetch(0)
      expect(drums.sample_folder).to eq("samples")
      expect(drums.samples[:kick]).to eq(File.join("samples", "kick.wav"))
      expect(drums.samples[:snare]).to eq(File.join("samples", "drums/snare.wav"))
    end

    it "validates constructor arguments and duplicate track names" do
      expect do
        described_class.build_definition(format: format, tempo: 0)
      end.to raise_error(Wavify::SequencerError, /tempo/)
      expect do
        described_class.build_definition(format: format, default_bars: 0)
      end.to raise_error(Wavify::SequencerError, /bars/)
      expect do
        described_class.build_definition(format: format) do
          track(:lead)
          track(:lead)
        end
      end.to raise_error(Wavify::SequencerError, /duplicate track name/)
      expect do
        described_class.build_definition(format: format, tempo: Float::INFINITY)
      end.to raise_error(Wavify::SequencerError, /finite/)
      expect do
        described_class.build_definition(format: format) do
          track(:lead) { gain("loud") }
        end
      end.to raise_error(Wavify::SequencerError, /gain/)
      expect do
        described_class.build_definition(format: format) do
          track(:lead) { pan(Float::NAN) }
        end
      end.to raise_error(Wavify::SequencerError, /pan/)
    end

    it "deep-freezes compiled track and section values" do
      song = described_class.build_definition(format: format) do
        track :lead do
          notes "C4"
          effect :chorus, rate: 1.0
        end
        arrange { section :main, bars: 1, tracks: [:lead], markers: [:start] }
      end

      expect(song).to be_frozen
      expect(song.tracks.first).to be_frozen
      expect(song.tracks.first.effects).to be_frozen
      expect(song.tracks.first.effects.first[:params]).to be_frozen
      expect(song.sections.first).to be_frozen
      expect(song.sections.first.tracks).to be_frozen
    end

    it "passes hold, curve, and synth options into rendering" do
      song = described_class.build_definition(format: format) do
        track :lead do
          synth :pulse, pulse_width: 0.25, detune: 4.0, unison: 3
          notes "C4"
          envelope attack: 0.0, hold: 0.01, decay: 0.01, sustain: 0.5, release: 0.01, curve: :exp
        end
      end
      track = song.sequencer_tracks.first

      expect(track.synth_options).to eq(pulse_width: 0.25, detune: 4.0, unison: 3)
      expect(track.envelope.hold).to eq(0.01)
      expect(track.envelope.curve).to eq(:exp)
      expect(song.render.sample_frame_count).to be > 0
    end

    it "can deeply validate sample files before rendering" do
      song = described_class.build_definition(format: format) do
        track :drums do
          pattern :hit, "x---"
          sample :hit, "/definitely/missing/hit.wav"
        end
      end

      expect(song.validate!).to eq(true)
      expect { song.validate!(deep: true) }.to raise_error(Wavify::SequencerError, /failed to inspect sample/)
    end

    it "can enforce sample-folder containment" do
      expect do
        described_class.build_definition(format: format, safe_paths: true) do
          sample_folder "/samples"
          track(:drums) { sample :hit, "../secret.wav" }
        end
      end.to raise_error(Wavify::SequencerError, /escapes sample_folder/)
    end

    it "rejects an ambiguous primary pattern with multiple samples" do
      song = described_class.build_definition(format: format) do
        track :drums do
          pattern "x---"
          sample :kick, "kick.wav"
          sample :snare, "snare.wav"
        end
      end

      expect do
        song.validate!
      end.to raise_error(Wavify::SequencerError, /ambiguous/)
    end
  end

  describe ".validate" do
    it "validates a DSL definition without rendering audio" do
      expect(
        described_class.validate(format: format) do
          track :lead do
            notes "C4 . E4 ."
          end
        end
      ).to be(true)
    end

    it "adds track context to validation errors" do
      expect do
        described_class.validate(format: format) do
          track :drums do
            pattern "x-o-"
          end
        end
      end.to raise_error(Wavify::SequencerError, /track :drums: invalid pattern symbol/)
    end

    it "adds arrangement context to section errors" do
      expect do
        described_class.build_definition(format: format) do
          arrange do
            section :bad, bars: 0, tracks: [:lead]
          end
        end
      end.to raise_error(Wavify::SequencerError, /arrangement: bars/)
    end

    it "uses custom registered effects" do
      custom_effect = Class.new do
        def initialize(scale:)
          @scale = scale
        end

        def process(buffer)
          Wavify::Core::SampleBuffer.new(buffer.samples.map { |sample| sample * @scale }, buffer.format)
        end
      end

      described_class.effect(:test_dsl_scale, custom_effect)
      song = described_class.build_definition(format: format, tempo: 120) do
        track :lead do
          notes "C4"
          effect :test_dsl_scale, scale: 0.1
        end
      end

      expect(song.render(default_bars: 1).peak_amplitude).to be < 0.2
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

    it "preserves empty rest sections and pads mixes and stems through the planned duration" do
      song = described_class.build_definition(format: format, tempo: 120) do
        track :lead do
          notes "C4", resolution: 4
        end

        arrange do
          section :intro, bars: 1, tracks: []
          section :main, bars: 1, tracks: [:lead]
          section :outro, bars: 1, tracks: []
        end
      end

      lead_start_frame = (song.timeline.find { |event| event[:track] == :lead }.fetch(:start_time) * format.sample_rate).round
      mix = song.render
      stem = song.render(stems: true).fetch(:lead)
      expected_frames = (song.duration.total_seconds * format.sample_rate).round

      [mix, stem].each do |audio|
        samples_before_lead = audio.buffer.samples.first(lead_start_frame * format.channels)
        trailing_bar = audio.buffer.samples.last((2.0 * format.sample_rate).round * format.channels)

        expect(audio.sample_frame_count).to eq(expected_frames)
        expect(samples_before_lead).to all(eq(0.0))
        expect(audio.buffer.samples.any? { |sample| sample.abs.positive? }).to eq(true)
        expect(trailing_bar).to all(eq(0.0))
      end
    end

    it "applies swing timing to DSL timelines" do
      song = described_class.build_definition(format: format, tempo: 120, swing: 0.6) do
        track :drums do
          pattern "xx--", resolution: 4
        end
      end

      trigger_times = song.timeline.map { |event| event[:start_time] }
      expect(trigger_times).to eq([0.0, 0.6])
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

      expect(song.arrangement.map { |section| section[:name] }).to eq([:loop])
      expect(song.arrangement.first[:repeat]).to eq(2)
      expect(song.duration.total_seconds).to be_within(0.0001).of(4.0)

      parsed = JSON.parse(song.timeline_json)
      expect(parsed).not_to be_empty
      expect(parsed.any? { |event| event["bar"] == 1 }).to be(true)

      text = song.timeline_text
      expect(text).to include("time\tbar\ttrack\tkind\tdetail")
      expect(text).to include("lead", "note")
    end

    it "supports global key, chord voicing, section tempo/meter, and markers" do
      song = described_class.build_definition(format: format, tempo: 120, default_bars: 1) do
        key :c, :minor

        track :lead do
          notes "C#4/8. D#4/8t"
        end

        track :pad do
          chords ["Cmaj7"], voicing: :drop2
        end

        arrange do
          section :intro, bars: 1, tracks: [:lead], markers: [:start]
          section :bridge, bars: 1, tracks: %i[lead pad], tempo: 60, beats_per_bar: 3, markers: [:bridge]
        end
      end

      timeline = song.timeline
      markers = timeline.select { |event| event[:kind] == "marker" || event[:kind] == :marker }
      lead_notes = timeline.select { |event| event[:kind] == :note && event[:track] == :lead }
      pad_chord = timeline.find { |event| event[:kind] == :chord && event[:track] == :pad }

      expect(song.duration.total_seconds).to be_within(0.0001).of(5.0)
      expect(markers.map { |event| event[:marker] }).to eq(%i[start bridge])
      expect(lead_notes.first[:midi_notes]).to eq([60])
      expect(lead_notes.first[:duration]).to be_within(0.0001).of(0.375)
      expect(pad_chord[:midi_notes]).to eq([55, 60, 63, 70])
      expect(song.timeline_text).to include("marker=bridge")
    end

    it "adds the lofi drums preset track definition" do
      song = described_class.build_definition(format: format, tempo: 90) do
        sample_folder "samples"
        preset :lofi_drums
      end

      drums = song.tracks.fetch(0)
      expect(drums.name).to eq(:lofi_drums)
      expect(drums.named_patterns.keys).to eq(%i[kick snare hat])
      expect(drums.samples[:kick]).to eq(File.join("samples", "kick.wav"))
      expect(drums.effects.first[:name]).to eq(:compressor)
    end

    it "does not double-prefix an overridden preset sample folder" do
      song = described_class.build_definition(format: format) do
        sample_folder "global"
        preset :lofi_drums, sample_folder: "other"
      end

      expect(song.tracks.first.samples[:kick]).to eq(File.join("other", "kick.wav"))
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

    it "sanitizes stem names and publishes files only after every encode succeeds" do
      song = described_class.build_definition(format: format, tempo: 120) do
        track(:"../lead") { notes "C4" }
        track(:pad) { notes "E4" }
      end

      Dir.mktmpdir("wavify_stem_parent") do |parent|
        directory = File.join(parent, "stems")
        paths = song.write_stems(directory)
        expect(paths[:"../lead"]).to start_with("#{File.expand_path(directory)}#{File::SEPARATOR}")
        expect(File.basename(paths[:"../lead"])).not_to include("..", "/")

        FileUtils.rm_rf(directory)
        allow_any_instance_of(Wavify::Audio).to receive(:write).and_wrap_original do |method, path, **options|
          raise Wavify::ProcessingError, "encode failed" if File.basename(path) == "pad.wav"

          method.call(path, **options)
        end
        expect { song.write_stems(directory) }.to raise_error(Wavify::ProcessingError, /encode failed/)
        expect(Dir.exist?(directory)).to eq(false)
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

        expect(audio.sample_frame_count).to eq((song.duration.total_seconds * format.sample_rate).round)
        left, right = audio.buffer.samples.first(2)
        expect(left.abs).to be < 0.001
        expect(right).to be_within(0.01).of(0.8 * (10.0**(-6.0 / 20.0)))
      end
    end

    it "applies per-sample pitch while rendering" do
      Tempfile.create(["wavify_pitch", ".wav"]) do |hit|
        source = Wavify::Core::SampleBuffer.new([0.2, 0.2, 0.4, 0.4, 0.6, 0.6, 0.8, 0.8], format)
        Wavify::Audio.new(source).write(hit.path)

        song = described_class.build_definition(format: format, tempo: 120) do
          track :drums do
            pattern :hit, "X---"
            sample :hit, hit.path, pitch: 12
          end
        end

        audio = song.render(default_bars: 1)

        expect(audio.sample_frame_count).to eq((song.duration.total_seconds * format.sample_rate).round)
        expect(audio.buffer.samples.first(4).any? { |sample| sample.abs.positive? }).to eq(true)
        expect(audio.buffer.samples.drop(4)).to all(eq(0.0))
      end
    end

    it "rolls pattern probability with a reproducible seed" do
      Tempfile.create(["wavify_probability", ".wav"]) do |hit|
        sample_buffer = Wavify::Core::SampleBuffer.new(Array.new(8, 0.5), format)
        Wavify::Audio.new(sample_buffer).write(hit.path)
        song = described_class.build_definition(format: format, tempo: 120, random_seed: 123) do
          track :drums do
            pattern :hit, "x?50x?50"
            sample :hit, hit.path
          end
        end

        first = song.render(default_bars: 1)
        second = song.render(default_bars: 1)

        expect(first.buffer.samples).to eq(second.buffer.samples)
        expect(first.peak_amplitude).to be > 0.0
        expect(song.send(:derived_track_seed, :drums)).not_to eq(song.send(:derived_track_seed, :bass))
      end
    end


    it "preserves overlapping sample peaks until track effects or final output" do
      Tempfile.create(["wavify_overlap_a", ".wav"]) do |first|
        Tempfile.create(["wavify_overlap_b", ".wav"]) do |second|
          audio_sample = Wavify::Audio.new(Wavify::Core::SampleBuffer.new(Array.new(8, 1.0), format))
          audio_sample.write(first.path)
          audio_sample.write(second.path)
          song = described_class.build_definition(format: format, tempo: 120) do
            track :drums do
              pattern :first, "x---"
              pattern :second, "x---"
              sample :first, first.path
              sample :second, second.path
            end
          end

          expect(song.render(default_bars: 1).peak_amplitude).to be > 1.0
        end
      end
    end
  end
end
