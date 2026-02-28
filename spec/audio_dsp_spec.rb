# frozen_string_literal: true

RSpec.describe Wavify::Audio do
  let(:float_stereo) { Wavify::Core::Format.new(channels: 2, sample_rate: 44_100, bit_depth: 32, sample_format: :float) }

  def audio_with(samples, format = float_stereo)
    buffer = Wavify::Core::SampleBuffer.new(samples, format)
    described_class.new(buffer)
  end

  describe "dsp transforms" do
    it "applies gain immutably and mutably" do
      audio = audio_with([0.25, -0.25, 0.5, -0.5])
      louder = audio.gain(6.0)

      expect(louder).not_to equal(audio)
      expect(louder.peak_amplitude).to be > audio.peak_amplitude

      original_peak = audio.peak_amplitude
      audio.gain!(6.0)
      expect(audio.peak_amplitude).to be > original_peak
    end

    it "normalizes to the requested peak level" do
      audio = audio_with([0.1, -0.1, 0.2, -0.2])
      normalized = audio.normalize(target_db: -6.0)

      expect(normalized.peak_amplitude).to be_within(0.01).of(10.0**(-6.0 / 20.0))
    end

    it "trims leading and trailing silence" do
      audio = audio_with([0.0, 0.0, 0.25, -0.25, 0.0, 0.0])
      trimmed = audio.trim(threshold: 0.1)

      expect(trimmed.sample_frame_count).to eq(1)
      expect(trimmed.buffer.samples).to eq([0.25, -0.25])
    end

    it "applies fade in and fade out" do
      audio = audio_with([1.0, -1.0, 1.0, -1.0, 1.0, -1.0, 1.0, -1.0])
      faded = audio.fade_in(2.0 / 44_100).fade_out(2.0 / 44_100)

      expect(faded.buffer.samples.first.abs).to be < 0.1
      expect(faded.buffer.samples.last.abs).to be < 0.1
    end

    it "pans mono audio to stereo" do
      mono = Wavify::Core::Format.new(channels: 1, sample_rate: 44_100, bit_depth: 32, sample_format: :float)
      audio = audio_with([0.5, 0.5], mono)
      panned = audio.pan(1.0)

      expect(panned.format.channels).to eq(2)
      first_left, first_right = panned.buffer.samples[0, 2]
      expect(first_left.abs).to be < 0.05
      expect(first_right).to be > 0.4
    end

    it "reverses audio by sample frame" do
      audio = audio_with([1.0, -1.0, 0.2, -0.2, 0.4, -0.4])
      reversed = audio.reverse

      expect(reversed.buffer.samples).to eq([0.4, -0.4, 0.2, -0.2, 1.0, -1.0])
    end

    it "applies custom effect objects" do
      effect = Class.new do
        def process(buffer)
          format = buffer.format.with(sample_format: :float, bit_depth: 32)
          float = buffer.convert(format)
          scaled = float.samples.map { |sample| sample * 0.5 }
          Wavify::Core::SampleBuffer.new(scaled, format).convert(buffer.format)
        end
      end.new

      audio = audio_with([0.4, -0.4, 0.2, -0.2])
      processed = audio.apply(effect)

      expect(processed.peak_amplitude).to be_within(0.01).of(0.2)
    end
  end

  describe "analysis and generators" do
    it "calculates peak and rms amplitude" do
      audio = audio_with([0.5, -0.5, 0.5, -0.5])

      expect(audio.peak_amplitude).to be_within(0.0001).of(0.5)
      expect(audio.rms_amplitude).to be_within(0.001).of(0.5)
    end

    it "creates tones via oscillator" do
      audio = described_class.tone(
        frequency: 440,
        duration: 0.1,
        waveform: :sine,
        format: float_stereo
      )

      expect(audio.sample_frame_count).to eq(4_410)
      expect(audio.format).to eq(float_stereo)
    end
  end
end
