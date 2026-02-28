# frozen_string_literal: true

module Wavify
  # High-level immutable audio object backed by a {Core::SampleBuffer}.
  #
  # Most processing methods return a new instance and expose `!` variants for
  # in-place replacement of the internal buffer.
  class Audio
    attr_reader :buffer

    # Reads audio from a file path using codec auto-detection.
    #
    # @param path [String]
    # @param format [Core::Format, nil] optional target format to convert into
    # @param codec_options [Hash] codec-specific options forwarded to `.read`
    # @return [Audio]
    def self.read(path, format: nil, codec_options: nil)
      codec = Codecs::Registry.detect(path)
      options = codec_options || {}
      raise InvalidParameterError, "codec_options must be a Hash" unless options.is_a?(Hash)

      new(codec.read(path, format: format, **options))
    end

    # Mixes multiple audio objects and clips summed samples into range.
    #
    # @param audios [Array<Audio>]
    # @return [Audio]
    def self.mix(*audios)
      raise InvalidParameterError, "at least one Audio is required" if audios.empty?
      raise InvalidParameterError, "all arguments must be Audio instances" unless audios.all? { |audio| audio.is_a?(self) }

      sample_rates = audios.map { |audio| audio.format.sample_rate }.uniq
      raise InvalidParameterError, "all audios must have the same sample_rate to mix" if sample_rates.length > 1

      target_format = audios.first.format
      work_format = target_format.with(sample_format: :float, bit_depth: 32)
      converted = audios.map { |audio| audio.buffer.convert(work_format) }
      max_frames = converted.map(&:sample_frame_count).max || 0
      channels = work_format.channels
      mixed = Array.new(max_frames * channels, 0.0)

      converted.each do |buffer|
        buffer.samples.each_with_index do |sample, index|
          mixed[index] += sample
        end
      end

      mixed.map! { |sample| clip_value(sample, -1.0, 1.0) }
      new(Core::SampleBuffer.new(mixed, work_format).convert(target_format))
    end

    # Creates a streaming processing pipeline for an input path/IO.
    #
    # @param path_or_io [String, IO]
    # @param chunk_size [Integer] chunk size in frames
    # @param format [Core::Format, nil] optional source format override
    # @param codec_options [Hash] codec-specific options forwarded to `.stream_read`
    # @return [Core::Stream]
    def self.stream(path_or_io, chunk_size: 4096, format: nil, codec_options: nil)
      codec = Codecs::Registry.detect(path_or_io)
      source_format = format || codec.metadata(path_or_io)[:format]
      options = codec_options || {}
      raise InvalidParameterError, "codec_options must be a Hash" unless options.is_a?(Hash)

      stream = Core::Stream.new(
        path_or_io,
        codec: codec,
        format: source_format,
        chunk_size: chunk_size,
        codec_read_options: options
      )
      return stream unless block_given?

      yield stream
      stream
    end

    # Generates a tone using the built-in oscillator.
    #
    # @param frequency [Numeric] oscillator frequency in Hz
    # @param duration [Numeric] duration in seconds
    # @param format [Core::Format] output format
    # @param waveform [Symbol] `:sine`, `:square`, `:triangle`, `:sawtooth`, `:white_noise`
    # @return [Audio]
    def self.tone(frequency:, duration:, format:, waveform: :sine)
      oscillator = DSP::Oscillator.new(
        waveform: waveform,
        frequency: frequency
      )
      new(oscillator.generate(duration, format: format))
    end

    # Builds silent audio in the requested format.
    #
    # @param duration_seconds [Numeric]
    # @param format [Core::Format]
    # @return [Audio]
    def self.silence(duration_seconds, format:)
      unless duration_seconds.is_a?(Numeric) && duration_seconds >= 0
        raise InvalidParameterError, "duration_seconds must be a non-negative Numeric: #{duration_seconds.inspect}"
      end
      raise InvalidParameterError, "format must be Core::Format" unless format.is_a?(Core::Format)

      frame_count = (duration_seconds.to_f * format.sample_rate).round
      default_sample = format.sample_format == :float ? 0.0 : 0
      samples = Array.new(frame_count * format.channels, default_sample)
      new(Core::SampleBuffer.new(samples, format))
    end

    # @param buffer [Core::SampleBuffer]
    def initialize(buffer)
      raise InvalidParameterError, "buffer must be Core::SampleBuffer" unless buffer.is_a?(Core::SampleBuffer)

      @buffer = buffer
    end

    # Writes the audio to a file path using codec auto-detection.
    #
    # @param path [String]
    # @param format [Core::Format, nil] optional output format
    # @return [Audio] self
    def write(path, format: nil)
      codec = Codecs::Registry.detect(path)
      codec.write(path, @buffer, format: format || @buffer.format)
      self
    end

    # @return [Core::Format]
    def format
      @buffer.format
    end

    # @return [Core::Duration]
    def duration
      @buffer.duration
    end

    # @return [Integer] frame count
    def sample_frame_count
      @buffer.sample_frame_count
    end

    # Converts to a new format/channels.
    #
    # @param new_format [Core::Format]
    # @return [Audio]
    def convert(new_format)
      self.class.new(@buffer.convert(new_format))
    end

    # Splits the audio into two clips at a time offset.
    #
    # @param at [Numeric, Core::Duration] split point in seconds
    # @return [Array<Audio>] `[left, right]`
    def split(at:)
      split_frame = coerce_split_point_to_frame(at)
      left = @buffer.slice(0, split_frame)
      right = @buffer.slice(split_frame, [@buffer.sample_frame_count - split_frame, 0].max)

      [self.class.new(left), self.class.new(right)]
    end

    # Repeats the audio content.
    #
    # @param times [Integer] repetition count
    # @return [Audio]
    def loop(times:)
      raise InvalidParameterError, "times must be a non-negative Integer" unless times.is_a?(Integer) && times >= 0

      return self.class.new(Core::SampleBuffer.new([], @buffer.format)) if times.zero?

      result = @buffer
      (times - 1).times { result += @buffer }
      self.class.new(result)
    end

    # In-place variant of {#loop}.
    #
    # @param times [Integer]
    # @return [Audio] self
    def loop!(times:)
      replace_buffer!(self.loop(times: times).buffer)
      self
    end

    # Reverses sample frame order.
    #
    # @return [Audio]
    def reverse
      self.class.new(@buffer.reverse)
    end

    # In-place variant of {#reverse}.
    #
    # @return [Audio] self
    def reverse!
      replace_buffer!(reverse.buffer)
      self
    end

    # Applies linear gain in decibels.
    #
    # @param db [Numeric]
    # @return [Audio]
    def gain(db)
      factor = 10.0**(db.to_f / 20.0)
      transform_samples do |samples, _format|
        samples.map { |sample| (sample * factor).clamp(-1.0, 1.0) }
      end
    end

    # In-place variant of {#gain}.
    #
    # @param db [Numeric]
    # @return [Audio] self
    def gain!(db)
      replace_buffer!(gain(db).buffer)
      self
    end

    # Scales audio so the peak amplitude reaches the target dBFS.
    #
    # @param target_db [Numeric]
    # @return [Audio]
    def normalize(target_db: 0.0)
      transform_samples do |samples, _format|
        peak = samples.map(&:abs).max || 0.0
        next samples if peak.zero?

        target = 10.0**(target_db.to_f / 20.0)
        factor = target / peak
        samples.map { |sample| (sample * factor).clamp(-1.0, 1.0) }
      end
    end

    # In-place variant of {#normalize}.
    #
    # @param target_db [Numeric]
    # @return [Audio] self
    def normalize!(target_db: 0.0)
      replace_buffer!(normalize(target_db: target_db).buffer)
      self
    end

    # Removes leading and trailing frames below a threshold.
    #
    # @param threshold [Numeric] amplitude threshold in 0.0..1.0
    # @return [Audio]
    def trim(threshold: 0.01)
      raise InvalidParameterError, "threshold must be Numeric in 0.0..1.0" unless threshold.is_a?(Numeric) && threshold.between?(0.0, 1.0)

      float_buffer = @buffer.convert(float_work_format(@buffer.format))
      channels = float_buffer.format.channels
      frames = float_buffer.samples.each_slice(channels).to_a
      first = frames.index { |frame| frame.any? { |sample| sample.abs >= threshold } }
      return self.class.new(Core::SampleBuffer.new([], @buffer.format)) unless first

      last = frames.rindex { |frame| frame.any? { |sample| sample.abs >= threshold } }
      trimmed = frames[first..last].flatten
      self.class.new(Core::SampleBuffer.new(trimmed, float_buffer.format).convert(@buffer.format))
    end

    # In-place variant of {#trim}.
    #
    # @param threshold [Numeric]
    # @return [Audio] self
    def trim!(threshold: 0.01)
      replace_buffer!(trim(threshold: threshold).buffer)
      self
    end

    # Applies a linear fade-in.
    #
    # @param seconds [Numeric]
    # @return [Audio]
    def fade_in(seconds)
      apply_fade(seconds: seconds, mode: :in)
    end

    # In-place variant of {#fade_in}.
    #
    # @param seconds [Numeric]
    # @return [Audio] self
    def fade_in!(seconds)
      replace_buffer!(fade_in(seconds).buffer)
      self
    end

    # Applies a linear fade-out.
    #
    # @param seconds [Numeric]
    # @return [Audio]
    def fade_out(seconds)
      apply_fade(seconds: seconds, mode: :out)
    end

    # In-place variant of {#fade_out}.
    #
    # @param seconds [Numeric]
    # @return [Audio] self
    def fade_out!(seconds)
      replace_buffer!(fade_out(seconds).buffer)
      self
    end

    # Constant-power pan for mono/stereo sources.
    #
    # Mono inputs are first upmixed to stereo.
    #
    # @param position [Numeric] `-1.0` (left) to `1.0` (right)
    # @return [Audio]
    def pan(position)
      validate_pan_position!(position)

      case @buffer.format.channels
      when 1
        source_format = @buffer.format.with(channels: 2)
      when 2
        source_format = @buffer.format
      else
        raise InvalidParameterError, "pan is only supported for mono/stereo input"
      end

      transform_samples(target_format: source_format) do |samples, _format|
        left_gain, right_gain = constant_power_pan_gains(position.to_f)
        result = samples.dup
        result.each_slice(2).with_index do |(left, right), frame_index|
          base = frame_index * 2
          result[base] = (left * left_gain).clamp(-1.0, 1.0)
          result[base + 1] = (right * right_gain).clamp(-1.0, 1.0)
        end
        result
      end
    end

    # In-place variant of {#pan}.
    #
    # @param position [Numeric]
    # @return [Audio] self
    def pan!(position)
      replace_buffer!(pan(position).buffer)
      self
    end

    # Applies an effect/processor object to the audio buffer.
    #
    # Accepted interfaces: `#process`, `#call`, or `#apply`.
    #
    # @param effect [Object]
    # @return [Audio]
    def apply(effect)
      processed = if effect.respond_to?(:process)
                    effect.process(@buffer)
                  elsif effect.respond_to?(:call)
                    effect.call(@buffer)
                  elsif effect.respond_to?(:apply)
                    effect.apply(@buffer)
                  else
                    raise InvalidParameterError, "effect must respond to :process, :call, or :apply"
                  end

      raise ProcessingError, "effect must return Core::SampleBuffer" unless processed.is_a?(Core::SampleBuffer)

      self.class.new(processed)
    end

    # In-place variant of {#apply}.
    #
    # @param effect [Object]
    # @return [Audio] self
    def apply!(effect)
      replace_buffer!(apply(effect).buffer)
      self
    end

    # Returns the absolute peak amplitude in float working space.
    #
    # @return [Float] 0.0..1.0
    def peak_amplitude
      float_buffer = @buffer.convert(float_work_format(@buffer.format))
      float_buffer.samples.map(&:abs).max || 0.0
    end

    # Returns RMS amplitude in float working space.
    #
    # @return [Float] 0.0..1.0
    def rms_amplitude
      float_buffer = @buffer.convert(float_work_format(@buffer.format))
      return 0.0 if float_buffer.samples.empty?

      square_sum = float_buffer.samples.sum { |sample| sample * sample }
      Math.sqrt(square_sum / float_buffer.samples.length)
    end

    private

    def apply_fade(seconds:, mode:)
      raise InvalidParameterError, "seconds must be a non-negative Numeric" unless seconds.is_a?(Numeric) && seconds >= 0

      transform_samples do |samples, format|
        channels = format.channels
        sample_frames = samples.length / channels
        fade_frames = [(seconds.to_f * format.sample_rate).round, sample_frames].min
        return samples if fade_frames.zero?

        result = samples.dup
        start_frame = sample_frames - fade_frames

        result.each_slice(channels).with_index do |frame, frame_index|
          factor = case mode
                   when :in
                     frame_index < fade_frames ? frame_index.to_f / fade_frames : 1.0
                   when :out
                     frame_index >= start_frame ? (sample_frames - frame_index - 1).to_f / fade_frames : 1.0
                   else
                     1.0
                   end

          factor = factor.clamp(0.0, 1.0)
          base = frame_index * channels
          frame.each_index do |channel_index|
            result[base + channel_index] = (frame[channel_index] * factor).clamp(-1.0, 1.0)
          end
        end

        result
      end
    end

    def transform_samples(target_format: @buffer.format)
      raise InvalidParameterError, "target_format must be Core::Format" unless target_format.is_a?(Core::Format)

      work_format = float_work_format(target_format)
      working_buffer = @buffer.convert(work_format)
      transformed_samples = yield(working_buffer.samples.dup, work_format)
      processed = Core::SampleBuffer.new(transformed_samples, work_format).convert(target_format)
      self.class.new(processed)
    end

    def float_work_format(format)
      format.with(sample_format: :float, bit_depth: 32)
    end

    def constant_power_pan_gains(position)
      angle = (position + 1.0) * (Math::PI / 4.0)
      [Math.cos(angle), Math.sin(angle)]
    end

    def validate_pan_position!(position)
      raise InvalidParameterError, "position must be Numeric in -1.0..1.0" unless position.is_a?(Numeric) && position.between?(-1.0, 1.0)
    end

    def replace_buffer!(new_buffer)
      raise InvalidParameterError, "buffer must be Core::SampleBuffer" unless new_buffer.is_a?(Core::SampleBuffer)

      @buffer = new_buffer
    end

    def coerce_split_point_to_frame(at)
      frame = case at
              when Core::Duration
                (at.total_seconds * @buffer.format.sample_rate).round
              when Numeric
                (at.to_f * @buffer.format.sample_rate).round
              else
                raise InvalidParameterError, "split point must be Numeric or Core::Duration"
              end

      raise InvalidParameterError, "split point is out of range: #{frame}" if frame.negative? || frame > @buffer.sample_frame_count

      frame
    end

    def self.clip_value(value, min, max)
      return min if value < min
      return max if value > max

      value
    end
    private_class_method :clip_value
  end
end
