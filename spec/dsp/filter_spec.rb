# frozen_string_literal: true

RSpec.describe Wavify::DSP::Filter do
  let(:mono_float) { Wavify::Core::Format.new(channels: 1, sample_rate: 44_100, bit_depth: 32, sample_format: :float) }

  def rms(samples)
    return 0.0 if samples.empty?

    Math.sqrt(samples.sum { |sample| sample * sample } / samples.length)
  end

  describe "frequency response" do
    it "attenuates high frequencies with lowpass" do
      high = Wavify::Audio.tone(frequency: 5_000, duration: 0.1, format: mono_float, waveform: :sine).buffer
      filter = described_class.lowpass(cutoff: 1_000)
      processed = filter.apply(high)

      expect(rms(processed.samples)).to be < (rms(high.samples) * 0.4)
    end

    it "attenuates low frequencies with highpass" do
      low = Wavify::Audio.tone(frequency: 120, duration: 0.1, format: mono_float, waveform: :sine).buffer
      filter = described_class.highpass(cutoff: 1_000)
      processed = filter.apply(low)

      expect(rms(processed.samples)).to be < (rms(low.samples) * 0.2)
    end
  end

  describe "streaming behavior" do
    it "preserves continuity across chunked processing" do
      tone_a = Wavify::Audio.tone(frequency: 440, duration: 0.1, format: mono_float, waveform: :sine).buffer
      tone_b = Wavify::Audio.tone(frequency: 1_200, duration: 0.1, format: mono_float, waveform: :sine).buffer
      source = tone_a + tone_b

      full_filter = described_class.lowpass(cutoff: 1_000)
      full = full_filter.apply(source)

      chunk_filter = described_class.lowpass(cutoff: 1_000)
      first = source.slice(0, source.sample_frame_count / 2)
      second = source.slice(source.sample_frame_count / 2, source.sample_frame_count)
      chunked = chunk_filter.apply(first) + chunk_filter.apply(second)

      differences = full.samples.zip(chunked.samples).map { |left, right| (left - right).abs }
      expect(differences.max).to be < 1e-5
    end

    it "keeps output stable over long noise input" do
      noise = Wavify::DSP::Oscillator.new(waveform: :white_noise, frequency: 1, amplitude: 0.7, random: Random.new(42))
      source = noise.generate(0.3, format: mono_float)
      filter = described_class.bandpass(center: 2_000, bandwidth: 400)
      processed = filter.apply(source)

      expect(processed.samples).to all(be_a(Float))
      expect(processed.samples.any?(&:nan?)).to be(false)
      expect(processed.samples.any?(&:infinite?)).to be(false)
    end
  end
end
