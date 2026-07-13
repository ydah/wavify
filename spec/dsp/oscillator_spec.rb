# frozen_string_literal: true

RSpec.describe Wavify::DSP::Oscillator do
  let(:mono_float) { Wavify::Core::Format.new(channels: 1, sample_rate: 8_000, bit_depth: 32, sample_format: :float) }

  describe "#generate" do
    it "generates a sine wave buffer" do
      oscillator = described_class.new(waveform: :sine, frequency: 440, amplitude: 1.0)
      buffer = oscillator.generate(0.01, format: mono_float)

      expect(buffer.sample_frame_count).to eq(80)
      expect(buffer.samples.first).to be_within(0.0001).of(0.0)
      expect(buffer.samples.max).to be <= 1.0
      expect(buffer.samples.min).to be >= -1.0
    end

    it "duplicates samples across channels for multichannel format" do
      stereo_float = mono_float.with(channels: 2)
      oscillator = described_class.new(waveform: :square, frequency: 110, amplitude: 0.5)
      buffer = oscillator.generate(0.005, format: stereo_float)

      expect(buffer.format.channels).to eq(2)
      buffer.samples.each_slice(2) do |left, right|
        expect(left).to eq(right)
      end
    end

    it "generates pulse waves with configurable width" do
      narrow = described_class.new(waveform: :pulse, frequency: 100, pulse_width: 0.25)
      wide = described_class.new(waveform: :pulse, frequency: 100, pulse_width: 0.75)

      narrow_buffer = narrow.generate(0.01, format: mono_float)
      wide_buffer = wide.generate(0.01, format: mono_float)

      expect(narrow_buffer.samples).not_to eq(wide_buffer.samples)
      expect(narrow_buffer.samples).to all(be_between(-1.0, 1.0))
    end

    it "supports detuned unison voices" do
      plain = described_class.new(waveform: :sawtooth, frequency: 220)
      detuned = described_class.new(waveform: :sawtooth, frequency: 220, detune: 8.0, unison: 3)

      plain_buffer = plain.generate(0.02, format: mono_float)
      detuned_buffer = detuned.generate(0.02, format: mono_float)

      expect(detuned_buffer.samples).not_to eq(plain_buffer.samples)
      expect(detuned_buffer.samples).to all(be_between(-1.0, 1.0))
    end

    it "does not attenuate unison voices when detune is zero" do
      plain = described_class.new(waveform: :sine, frequency: 100)
      unison = described_class.new(waveform: :sine, frequency: 100, detune: 0.0, unison: 4)

      expect(unison.generate(0.02, format: mono_float).samples).to eq(plain.generate(0.02, format: mono_float).samples)
    end

    it "continues phase across consecutive generation calls" do
      chunked = described_class.new(waveform: :sine, frequency: 100, phase: 0.25)
      continuous = described_class.new(waveform: :sine, frequency: 100, phase: 0.25)

      chunks = chunked.generate(0.005, format: mono_float).samples + chunked.generate(0.005, format: mono_float).samples

      expect(chunks).to eq(continuous.generate(0.01, format: mono_float).samples)
    end

    it "generates independent noise values for each channel" do
      stereo = mono_float.with(channels: 2)
      oscillator = described_class.new(waveform: :white_noise, frequency: 1, random: Random.new(123))
      buffer = oscillator.generate(0.001, format: stereo)

      expect(buffer.samples.each_slice(2).any? { |left, right| left != right }).to eq(true)
    end

    it "limits triangle harmonics below Nyquist" do
      high_format = mono_float.with(sample_rate: 48_000)
      frequency = 18_000
      oscillator = described_class.new(waveform: :triangle, frequency: frequency)
      samples = oscillator.generate(0.01, format: high_format).samples
      fundamental_scale = 8.0 / (Math::PI * Math::PI)

      expected = samples.each_index.map do |index|
        fundamental_scale * Math.cos(2.0 * Math::PI * frequency * index / high_format.sample_rate)
      end
      error = samples.zip(expected).map { |actual, reference| (actual - reference).abs }.max
      expect(error).to be < 0.001
    end
  end

  describe "#each_sample" do
    it "returns an infinite enumerator of samples" do
      oscillator = described_class.new(waveform: :triangle, frequency: 220, amplitude: 0.8)
      enum = oscillator.each_sample(format: mono_float)
      values = 5.times.map { enum.next }

      expect(values.length).to eq(5)
      expect(values.max).to be <= 0.8
      expect(values.min).to be >= -0.8
    end

    it "can reset phase for repeatable oscillator output" do
      oscillator = described_class.new(waveform: :sine, frequency: 100, phase: 0.1)
      first = oscillator.generate(0.005, format: mono_float).samples

      oscillator.reset_phase
      second = oscillator.generate(0.005, format: mono_float).samples

      expect(second).to eq(first)
    end
  end

  describe "validation" do
    it "raises on unsupported waveform" do
      expect do
        described_class.new(waveform: :unknown, frequency: 440)
      end.to raise_error(Wavify::InvalidParameterError)
    end

    it "raises on invalid pulse width and unison" do
      expect do
        described_class.new(waveform: :pulse, frequency: 440, pulse_width: 1.2)
      end.to raise_error(Wavify::InvalidParameterError)

      expect do
        described_class.new(waveform: :sawtooth, frequency: 440, unison: 0)
      end.to raise_error(Wavify::InvalidParameterError)

      expect do
        described_class.new(waveform: :sine, frequency: 440, phase: Float::INFINITY)
      end.to raise_error(Wavify::InvalidParameterError)
    end
  end
end
