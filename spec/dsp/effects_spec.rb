# frozen_string_literal: true

RSpec.describe Wavify::DSP::Effects do
  let(:mono_float) { Wavify::Core::Format.new(channels: 1, sample_rate: 44_100, bit_depth: 32, sample_format: :float) }
  let(:stereo_float) { mono_float.with(channels: 2) }

  def impulse_buffer(length:, format: mono_float)
    samples = Array.new(length * format.channels, 0.0)
    samples[0] = 1.0
    Wavify::Core::SampleBuffer.new(samples, format)
  end

  def rms(samples)
    return 0.0 if samples.empty?

    Math.sqrt(samples.sum { |sample| sample * sample } / samples.length)
  end

  def first_audible_index(samples, threshold: 0.0001)
    samples.find_index { |sample| sample.abs > threshold }
  end

  describe Wavify::DSP::Effects::Delay do
    it "produces delayed repeats for an impulse" do
      effect = described_class.new(time: 1.0 / 44_100, feedback: 0.5, mix: 1.0)
      processed = effect.process(impulse_buffer(length: 6))

      expect(processed.samples[0]).to be_within(0.0001).of(0.0)
      expect(processed.samples[1]).to be_within(0.0001).of(1.0)
      expect(processed.samples[2]).to be_within(0.0001).of(0.5)
      expect(processed.samples[3]).to be_within(0.0001).of(0.25)
    end

    it "preserves state across chunked process calls" do
      effect = described_class.new(time: 2.0 / 44_100, feedback: 0.0, mix: 1.0)
      first = Wavify::Core::SampleBuffer.new([1.0, 0.0], mono_float)
      second = Wavify::Core::SampleBuffer.new([0.0, 0.0], mono_float)

      first_out = effect.process(first)
      second_out = effect.process(second)

      expect(first_out.samples).to eq([0.0, 0.0])
      expect(second_out.samples.first).to be_within(0.0001).of(1.0)
    end

    it "flushes delayed tail after input ends" do
      effect = described_class.new(time: 2.0 / 44_100, feedback: 0.0, mix: 1.0)
      effect.process(Wavify::Core::SampleBuffer.new([1.0], mono_float))

      tail = effect.flush(format: mono_float)

      expect(tail.samples.first(2)).to eq([0.0, 1.0])
    end

    it "builds tempo-synced delays from note values" do
      effect = described_class.beat(:eighth, tempo: 120, feedback: 0.0, mix: 0.5)

      expect(effect.tail_duration).to be_within(0.0001).of(0.25)

      triplet = described_class.beat("quarter", tempo: 120, triplet: true, feedback: 0.0, mix: 1.0)
      expect(triplet.tail_duration).to be_within(0.0001).of(1.0 / 3.0)
    end
  end

  describe Wavify::DSP::Effects::Reverb do
    it "creates a decaying tail from an impulse" do
      effect = described_class.new(room_size: 0.8, damping: 0.4, mix: 1.0)
      processed = effect.process(impulse_buffer(length: 5_000))

      tail = processed.samples[1_000..]
      expect(tail.any? { |sample| sample.abs > 0.0001 }).to be(true)
      expect(processed.samples.length).to eq(5_000)
    end

    it "reports a positive tail duration when wet signal is enabled" do
      expect(described_class.new(room_size: 0.5, mix: 0.3).tail_duration).to be > 0.0
      expect(described_class.new(room_size: 0.5, mix: 0.0).tail_duration).to eq(0.0)
    end

    it "delays only the wet path when pre_delay is configured" do
      dry = described_class.new(room_size: 0.2, damping: 0.0, mix: 1.0)
      delayed = described_class.new(room_size: 0.2, damping: 0.0, mix: 1.0, pre_delay: 10.0 / 44_100)

      dry_first = first_audible_index(dry.process(impulse_buffer(length: 3_000)).samples)
      delayed_first = first_audible_index(delayed.process(impulse_buffer(length: 3_000)).samples)

      expect(delayed_first - dry_first).to eq(10)
      expect(delayed.tail_duration).to be > dry.tail_duration
    end

    it "adjusts wet stereo width" do
      source = impulse_buffer(length: 3_000, format: stereo_float)
      normal = described_class.new(room_size: 0.2, damping: 0.0, mix: 1.0, width: 1.0).process(source)
      narrowed = described_class.new(room_size: 0.2, damping: 0.0, mix: 1.0, width: 0.0).process(source)

      normal_frame = normal.samples.each_slice(2).find { |left, right| left.abs > 0.0001 || right.abs > 0.0001 }
      narrowed_frame = narrowed.samples.each_slice(2).find { |left, right| left.abs > 0.0001 || right.abs > 0.0001 }

      expect((normal_frame.fetch(0) - normal_frame.fetch(1)).abs).to be > 0.0001
      expect(narrowed_frame.fetch(0)).to be_within(0.0001).of(narrowed_frame.fetch(1))
    end
  end

  describe Wavify::DSP::Effects::Chorus do
    it "modulates a tone while preserving length" do
      effect = described_class.new(rate: 0.8, depth: 0.7, mix: 0.6)
      source = Wavify::Audio.tone(frequency: 440, duration: 0.1, format: stereo_float, waveform: :sine).buffer
      processed = effect.process(source)

      expect(processed.samples.length).to eq(source.samples.length)
      differences = source.samples.zip(processed.samples).map { |left, right| (left - right).abs }
      expect(differences.max).to be > 0.0001
    end

    it "reports a short modulation tail" do
      expect(described_class.new(mix: 0.5).tail_duration).to eq(0.03)
      expect(described_class.new(mix: 0.0).tail_duration).to eq(0.0)
    end
  end

  describe Wavify::DSP::Effects::Distortion do
    it "saturates with tone shaping and mix control" do
      effect = described_class.new(drive: 1.0, tone: 0.2, mix: 1.0)
      source = Wavify::Core::SampleBuffer.new([0.0, 0.2, 0.5, 0.9, -0.9], mono_float)
      processed = effect.process(source)

      expect(processed.samples.max).to be <= 1.0
      expect(processed.samples.min).to be >= -1.0
      expect(processed.samples[3].abs).to be < source.samples[3].abs
    end
  end

  describe Wavify::DSP::Effects::Compressor do
    it "reduces peaks above threshold" do
      effect = described_class.new(threshold: -20.0, ratio: 8.0, attack: 0.0, release: 0.01)
      source = Wavify::Core::SampleBuffer.new([0.05, 0.1, 0.8, 0.8, 0.1, 0.05], mono_float)
      processed = effect.process(source)

      expect(processed.samples[2].abs).to be < source.samples[2].abs
      expect(processed.samples[0]).to be_within(0.01).of(source.samples[0])
    end

    it "supports makeup gain and soft knee controls" do
      effect = described_class.new(threshold: -20.0, ratio: 2.0, attack: 0.0, release: 0.01, makeup_gain: 6.0, knee: 6.0)
      source = Wavify::Core::SampleBuffer.new([0.05, 0.2, 0.5], mono_float)

      processed = effect.process(source)

      expect(processed.samples[0]).to be > source.samples[0]
      expect(processed.samples[2]).to be < 1.0
    end

    it "uses sidechain audio as the detector signal" do
      source = Wavify::Core::SampleBuffer.new([0.5, 0.5, 0.5, 0.5], mono_float)
      detector = Wavify::Core::SampleBuffer.new([0.0, 1.0, 1.0, 0.0], mono_float)
      effect = described_class.new(threshold: -18.0, ratio: 8.0, attack: 0.0, release: 0.0, sidechain: detector)

      processed = effect.process(source)

      expect(processed.samples[0]).to be_within(0.001).of(source.samples[0])
      expect(processed.samples[1]).to be < source.samples[1]
      expect(processed.samples[2]).to be < source.samples[2]
      expect(processed.samples[3]).to be_within(0.001).of(source.samples[3])
    end

    it "links stereo gain reduction to preserve channel balance" do
      stereo = mono_float.with(channels: 2)
      buffer = Wavify::Core::SampleBuffer.new([1.0, 0.25, 1.0, 0.25], stereo)
      effect = described_class.new(threshold: -20.0, ratio: 4.0, attack: 0.0, release: 0.0)

      processed = effect.process(buffer)

      processed.samples.each_slice(2) do |left, right|
        expect(left / right).to be_within(0.0001).of(4.0)
      end
    end

    it "rejects sample-wise processing that cannot preserve stereo linking" do
      expect do
        described_class.new.process_sample(1.0, channel: 0, sample_rate: 44_100)
      end.to raise_error(NotImplementedError, /frame-aware/)
    end
  end

  describe Wavify::DSP::Effects::Limiter do
    it "caps peaks at the requested ceiling" do
      effect = described_class.new(ceiling: -6.0206)
      source = Wavify::Core::SampleBuffer.new([0.25, 0.9, -0.9], mono_float)

      processed = effect.apply(source)

      expect(processed.samples.map(&:abs).max).to be_within(0.0001).of(0.5)
    end

    it "uses linked gain reduction instead of flattening every hot sample" do
      effect = described_class.new(ceiling: -6.0206, attack: 0.0, release: 0.05, lookahead: 0.002)
      source = Wavify::Core::SampleBuffer.new([0.8, 1.0, 0.8], mono_float)

      processed = effect.apply(source)

      expect(processed.samples.map(&:abs).max).to be <= 0.5
      expect(processed.samples.fetch(0)).to be < processed.samples.fetch(1)
      expect(effect.lookahead).to eq(0.002)
      expect(effect.latency).to eq(0.002)
    end

    it "flushes frames retained by streaming lookahead" do
      effect = described_class.new(ceiling: -6.0206, attack: 0.0, lookahead: 2.0 / 44_100)
      source = Wavify::Core::SampleBuffer.new([0.25, 0.9, -0.9], mono_float)

      processed = effect.process(source)
      tail = effect.flush(format: mono_float)

      expect(processed.sample_frame_count + tail.sample_frame_count).to eq(source.sample_frame_count + 2)
      expect((processed.samples + tail.samples).map(&:abs).max).to be <= 0.5
    end

    it "matches offline processing after compensating for streaming latency" do
      source = Wavify::Core::SampleBuffer.new([0.1, 0.8, -1.0, 0.2, 0.9, -0.4, 0.1], mono_float)
      options = { ceiling: -6.0206, attack: 0.001, release: 0.02, lookahead: 2.0 / 44_100 }
      offline = described_class.new(**options).apply(source)
      streaming = described_class.new(**options)
      first_chunk = streaming.process(source.slice(0, 3))
      second_chunk = streaming.process(source.slice(3, 4))
      tail = streaming.flush(format: mono_float)
      compensated = (first_chunk.samples + second_chunk.samples + tail.samples).drop(2).first(source.length)

      compensated.zip(offline.samples).each do |actual, expected|
        expect(actual).to be_within(0.000001).of(expected)
      end
    end

    it "scales peak detection linearly with input length" do
      counting_limiter_class = Class.new(described_class) do
        attr_reader :peak_calls

        private

        def frame_peak(frame)
          @peak_calls = (@peak_calls || 0) + 1
          super
        end
      end
      source = Wavify::Core::SampleBuffer.new(Array.new(4_000, 0.5), mono_float)
      offline = counting_limiter_class.new(lookahead: 0.005)
      streaming = counting_limiter_class.new(lookahead: 0.005)

      offline.apply(source)
      streaming.process(source)
      streaming.flush(format: mono_float)

      expect(offline.peak_calls).to be < (source.sample_frame_count * 3)
      expect(streaming.peak_calls).to be < (source.sample_frame_count * 3)
    end

    it "rejects sample-wise processing that cannot preserve lookahead semantics" do
      expect do
        described_class.new.process_sample(1.0, channel: 0, sample_rate: 44_100)
      end.to raise_error(NotImplementedError, /frame-aware/)
    end
  end

  describe Wavify::DSP::Effects::SoftLimiter do
    it "rounds off samples above the threshold" do
      effect = described_class.new(threshold: 0.5, ceiling: 0.9, drive: 1.0)
      source = Wavify::Core::SampleBuffer.new([0.25, 0.75, 1.0, -1.0], mono_float)

      processed = effect.process(source)

      expect(processed.samples[0]).to eq(0.25)
      expect(processed.samples[1]).to be < 0.75
      expect(processed.samples[2]).to be <= 0.9
      expect(processed.samples[3]).to be >= -0.9
    end
  end

  describe Wavify::DSP::Effects::NoiseGate do
    it "attenuates samples below the threshold" do
      effect = described_class.new(threshold: -20.0, floor: -80.0, attack: 0.0, hold: 0.0, release: 0.0)
      source = Wavify::Core::SampleBuffer.new([0.005, 0.2, -0.005, -0.2], mono_float)

      processed = effect.process(source)

      expect(processed.samples[0].abs).to be < 0.00001
      expect(processed.samples[1]).to be_within(0.0001).of(0.2)
      expect(processed.samples[2].abs).to be < 0.00001
      expect(processed.samples[3]).to be_within(0.0001).of(-0.2)
    end

    it "does not close at zero crossings of a steady signal above threshold" do
      source = Wavify::Audio.tone(frequency: 440, duration: 0.05, amplitude: 0.1, format: mono_float).buffer
      processed = described_class.new(threshold: -40.0).process(source)
      settled_index = (0.01 * mono_float.sample_rate).round

      processed.samples.drop(settled_index).zip(source.samples.drop(settled_index)).each do |actual, expected|
        expect(actual).to be_within(0.0001).of(expected)
      end
    end

    it "requires frame-aware processing for linked detection" do
      expect do
        described_class.new.process_sample(0.1, channel: 0, sample_rate: 44_100)
      end.to raise_error(NotImplementedError, /frame-aware/)
    end
  end

  describe Wavify::DSP::Effects::Tremolo do
    it "modulates amplitude while preserving length" do
      effect = described_class.new(rate: 25.0, depth: 1.0, mix: 1.0)
      source = Wavify::Core::SampleBuffer.new(Array.new(2_000, 1.0), mono_float)

      processed = effect.process(source)

      expect(processed.samples.length).to eq(source.samples.length)
      expect(processed.samples.min).to be < 0.1
      expect(processed.samples.max).to be <= 1.0
    end
  end

  describe Wavify::DSP::Effects::Vibrato do
    it "modulates pitch by changing sample timing while preserving length" do
      effect = described_class.new(rate: 7.0, depth: 1.0, mix: 1.0)
      source = Wavify::Audio.tone(frequency: 440, duration: 0.1, format: mono_float, waveform: :sine).buffer

      processed = effect.process(source)

      expect(processed.samples.length).to eq(source.samples.length)
      differences = source.samples.zip(processed.samples).map { |left, right| (left - right).abs }
      expect(differences.max).to be > 0.01
    end
  end

  describe Wavify::DSP::Effects::Flanger do
    it "creates a short comb modulation and reports a small tail" do
      effect = described_class.new(rate: 1.0, depth: 1.0, feedback: 0.2, mix: 0.8)
      source = Wavify::Audio.tone(frequency: 440, duration: 0.1, format: mono_float, waveform: :sine).buffer

      processed = effect.process(source)

      expect(processed.samples.length).to eq(source.samples.length)
      expect(effect.tail_duration).to eq(0.008)
      differences = source.samples.zip(processed.samples).map { |left, right| (left - right).abs }
      expect(differences.max).to be > 0.0001
    end
  end

  describe Wavify::DSP::Effects::Phaser do
    it "runs a modulated all-pass chain while preserving length" do
      effect = described_class.new(rate: 1.0, depth: 1.0, feedback: 0.2, mix: 0.8, stages: 4)
      source = Wavify::Audio.tone(frequency: 880, duration: 0.1, format: mono_float, waveform: :sine).buffer

      processed = effect.process(source)

      expect(processed.samples.length).to eq(source.samples.length)
      expect(processed.samples).to all(be_finite)
      differences = source.samples.zip(processed.samples).map { |left, right| (left - right).abs }
      expect(differences.max).to be > 0.0001
    end
  end

  describe Wavify::DSP::Effects::Bitcrusher do
    it "quantizes samples and holds values for downsampling" do
      effect = described_class.new(bit_depth: 2, downsample: 2, mix: 1.0)
      source = Wavify::Core::SampleBuffer.new([0.1, 0.4, 0.8, 0.2], mono_float)

      processed = effect.process(source)

      expect(processed.samples[0]).to eq(processed.samples[1])
      expect(processed.samples[2]).to eq(processed.samples[3])
      expect(processed.samples.uniq.length).to be <= 4
    end
  end

  describe Wavify::DSP::Effects::Expander do
    it "reduces low-level samples below threshold" do
      effect = described_class.new(threshold: -20.0, ratio: 2.0, floor: -80.0, attack: 0.0, hold: 0.0, release: 0.0)
      source = Wavify::Core::SampleBuffer.new([0.005, 0.2, -0.005, -0.2], mono_float)

      processed = effect.process(source)

      expect(processed.samples[0].abs).to be < source.samples[0].abs
      expect(processed.samples[1]).to be_within(0.0001).of(0.2)
      expect(processed.samples[2].abs).to be < source.samples[2].abs
      expect(processed.samples[3]).to be_within(0.0001).of(-0.2)
    end

    it "does not expand zero crossings of a steady signal above threshold" do
      source = Wavify::Audio.tone(frequency: 440, duration: 0.05, amplitude: 0.1, format: mono_float).buffer
      processed = described_class.new(threshold: -40.0).process(source)
      settled_index = (0.01 * mono_float.sample_rate).round

      processed.samples.drop(settled_index).zip(source.samples.drop(settled_index)).each do |actual, expected|
        expect(actual).to be_within(0.0001).of(expected)
      end
    end

    it "requires frame-aware processing for linked detection" do
      expect do
        described_class.new.process_sample(0.1, channel: 0, sample_rate: 44_100)
      end.to raise_error(NotImplementedError, /frame-aware/)
    end
  end

  describe Wavify::DSP::Effects::AutoPan do
    it "moves stereo signal between channels" do
      effect = described_class.new(rate: 30.0, depth: 1.0)
      source = Wavify::Core::SampleBuffer.new(Array.new(2_000, 1.0), stereo_float)

      processed = effect.process(source)

      left = processed.samples.each_slice(2).map(&:first)
      right = processed.samples.each_slice(2).map(&:last)
      expect(left.max - left.min).to be > 0.4
      expect(right.max - right.min).to be > 0.4
    end
  end

  describe Wavify::DSP::Effects::StereoWidener do
    it "adjusts stereo side information" do
      effect = described_class.new(width: 2.0)
      source = Wavify::Core::SampleBuffer.new([0.6, 0.2], stereo_float)

      processed = effect.process(source)

      expect(processed.samples[0]).to be_within(0.0001).of(0.8)
      expect(processed.samples[1]).to be_within(0.0001).of(0.0)
    end
  end

  describe Wavify::DSP::Effects::EQ do
    it "chains filters in order" do
      low = Wavify::Audio.tone(frequency: 120, duration: 0.1, format: mono_float, waveform: :sine).buffer
      eq = described_class.simple(highpass: 1_000)

      processed = eq.process(low)

      expect(rms(processed.samples)).to be < (rms(low.samples) * 0.2)
    end
  end

  describe Wavify::DSP::Effects::EffectChain do
    it "applies processors in order and exposes timing metadata" do
      chain = described_class.new([
        Wavify::DSP::Effects::Limiter.new(ceiling: -6.0206),
        Wavify::DSP::Effects::NoiseGate.new(threshold: -20.0, attack: 0.0, hold: 0.0, release: 0.0)
      ])

      processed = chain.apply(Wavify::Core::SampleBuffer.new([0.005, 1.0], mono_float))

      expect(processed.samples.first.abs).to be < 0.00001
      expect(processed.samples.last).to be_within(0.0001).of(0.5)
      expect(chain.latency).to eq(0.005)
      expect(chain.lookahead).to eq(0.005)
      expect(chain.tail_duration).to eq(0.005)
    end

    it "passes flushed tails through apply-only downstream effects" do
      tailing = Class.new do
        def process(buffer) = buffer

        def flush(format:)
          Wavify::Core::SampleBuffer.new([0.25], format)
        end
      end.new
      apply_only = Class.new do
        def apply(buffer)
          Wavify::Core::SampleBuffer.new(buffer.samples.map { |sample| sample * 2.0 }, buffer.format)
        end
      end.new
      chain = described_class.new([tailing, apply_only])

      chain.process(Wavify::Core::SampleBuffer.new([0.0], mono_float))

      expect(chain.flush(format: mono_float).samples).to eq([0.5])
    end
  end

  describe Wavify::DSP::Effects::MasteringChain do
    it "applies a compact mastering preset" do
      source = Wavify::Core::SampleBuffer.new([0.1, 1.0, -1.0, 0.2], mono_float)

      processed = described_class.new(ceiling: -3.0).process(source)

      expect(processed.samples.map(&:abs).max).to be <= (10.0**(-3.0 / 20.0))
    end
  end

  describe Wavify::DSP::Effects::PodcastChain do
    it "applies speech cleanup without changing length" do
      source = Wavify::Core::SampleBuffer.new([0.001, 0.001, 0.3, 0.3], mono_float)

      processed = described_class.new(ceiling: -3.0).process(source)

      expect(processed.samples.length).to eq(source.samples.length)
      expect(processed.samples).to all(be_finite)
      expect(processed.samples.map(&:abs).max).to be <= (10.0**(-3.0 / 20.0))
    end
  end

  describe "finite output regression coverage" do
    it "keeps built-in effects from emitting NaN or Infinity" do
      source = Wavify::Core::SampleBuffer.new(
        [
          0.0, 0.0,
          0.25, -0.25,
          0.95, -0.95,
          -1.0, 1.0,
          1.0, -1.0,
          0.05, -0.05
        ],
        stereo_float
      )
      effects = [
        Wavify::DSP::Effects::Delay.new(time: 1.0 / 44_100, feedback: 0.75, mix: 1.0),
        Wavify::DSP::Effects::Reverb.new(room_size: 0.9, damping: 0.1, mix: 1.0, pre_delay: 1.0 / 44_100, width: 1.5),
        Wavify::DSP::Effects::Chorus.new(rate: 2.0, depth: 0.7, mix: 1.0),
        Wavify::DSP::Effects::Distortion.new(drive: 1.0, tone: 0.5, mix: 1.0),
        Wavify::DSP::Effects::Compressor.new(threshold: -30.0, ratio: 10.0, attack: 0.0, release: 0.01, makeup_gain: 6.0, knee: 6.0),
        Wavify::DSP::Effects::Limiter.new(ceiling: -0.1, input_gain: 12.0),
        Wavify::DSP::Effects::SoftLimiter.new(threshold: 0.4, ceiling: 0.95, drive: 2.0),
        Wavify::DSP::Effects::NoiseGate.new(threshold: -60.0, floor: -90.0),
        Wavify::DSP::Effects::Expander.new(threshold: -20.0, ratio: 4.0, floor: -80.0),
        Wavify::DSP::Effects::Tremolo.new(rate: 10.0, depth: 1.0, mix: 1.0),
        Wavify::DSP::Effects::Vibrato.new(rate: 5.0, depth: 1.0, mix: 1.0),
        Wavify::DSP::Effects::Flanger.new(rate: 0.8, depth: 1.0, feedback: 0.5, mix: 1.0),
        Wavify::DSP::Effects::Phaser.new(rate: 0.8, depth: 1.0, feedback: 0.4, mix: 1.0),
        Wavify::DSP::Effects::AutoPan.new(rate: 4.0, depth: 1.0),
        Wavify::DSP::Effects::StereoWidener.new(width: 2.0),
        Wavify::DSP::Effects::Bitcrusher.new(bit_depth: 3, downsample: 3, mix: 1.0),
        Wavify::DSP::Effects::EQ.simple(highpass: 40.0, lowpass: 18_000.0, presence: { cutoff: 2_000.0, q: 1.0, gain_db: 3.0 }),
        Wavify::DSP::Effects::MasteringChain.new(ceiling: -0.1),
        Wavify::DSP::Effects::PodcastChain.new(ceiling: -0.1)
      ]

      effects.each do |effect|
        processed = effect.process(source)
        expect(processed.samples).to all(be_finite), "#{effect.class} emitted non-finite samples"
      end
    end
  end

  describe "registry" do
    it "builds registered effects from classes and factories" do
      custom_class = Class.new do
        def initialize(gain: 1.0)
          @gain = gain
        end

        def process(buffer)
          Wavify::Core::SampleBuffer.new(buffer.samples.map { |sample| sample * @gain }, buffer.format)
        end
      end

      expect(described_class.register(:test_gain_effect, custom_class)).to eq(custom_class)
      class_effect = described_class.build(:test_gain_effect, gain: 0.5)
      class_processed = class_effect.process(Wavify::Core::SampleBuffer.new([1.0], mono_float))
      expect(class_processed.samples).to eq([0.5])

      described_class.register(:test_callable_effect) do |gain:|
        custom_class.new(gain: gain)
      end
      callable_effect = described_class.build(:test_callable_effect, gain: 0.25)
      callable_processed = callable_effect.process(Wavify::Core::SampleBuffer.new([1.0], mono_float))
      expect(callable_processed.samples).to eq([0.25])

      expect(described_class.unregister(:test_gain_effect)).to eq(custom_class)
      expect do
        described_class.build(:test_gain_effect)
      end.to raise_error(Wavify::InvalidParameterError, /unsupported effect/)
      described_class.unregister(:test_callable_effect)
    end
  end

  it "exposes effects under Wavify::Effects alias" do
    expect(Wavify::Effects::Delay).to eq(Wavify::DSP::Effects::Delay)
  end
end
