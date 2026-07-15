# frozen_string_literal: true

require "tempfile"

module Wavify
  # High-level immutable audio object backed by a {Core::SampleBuffer}.
  #
  # Most processing methods return a new instance and expose `!` variants for
  # in-place replacement of the internal buffer.
  class Audio
    attr_reader :buffer

    # Supported policies for summing multiple sources.
    MIX_STRATEGIES = %i[none clip normalize headroom soft_limit].freeze
    # Supported timeline alignment modes for sources of different lengths.
    MIX_ALIGNMENTS = %i[start center end].freeze
    # Supported normalization reference measurements.
    NORMALIZE_MODES = %i[peak rms lufs].freeze
    # Supported fade interpolation curves.
    FADE_CURVES = %i[linear exp log].freeze
    # Knee threshold used by the built-in soft-limit mix policy.
    SOFT_LIMIT_THRESHOLD = 0.8
    # Maximum number of frames allowed by eager repeat.
    MAX_REPEAT_FRAMES = 50_000_000
    # Maximum estimated allocation allowed by eager repeat.
    MAX_REPEAT_BYTES = 512 * 1024 * 1024

    # Reads audio from a file path using codec auto-detection.
    #
    # @param path_or_io [String, IO]
    # @param format [Core::Format, nil] optional target format to convert into
    # @param codec_options [Hash] codec-specific options forwarded to `.read`
    # @param strict [Boolean] verify extension and magic-byte codec agreement
    # @param filename [String, nil] optional filename hint for IO inputs
    # @return [Audio]
    def self.read(path_or_io, format: nil, codec_options: nil, strict: false, filename: nil)
      codec = Codecs::Registry.detect_for_read(path_or_io, strict: strict, filename: filename)
      options = normalize_codec_options!(codec_options)

      new(codec.read(path_or_io, format: format, **options))
    end

    # Reads audio metadata without decoding the full payload when the codec supports it.
    #
    # @param path_or_io [String, IO]
    # @param format [Core::Format, nil] required for raw PCM/float input
    # @param codec_options [Hash] codec-specific options forwarded to `.metadata`
    # @param strict [Boolean] verify extension and magic-byte codec agreement
    # @param filename [String, nil] optional filename hint for IO inputs
    # @return [Hash]
    def self.metadata(path_or_io, format: nil, codec_options: nil, strict: false, filename: nil)
      codec = Codecs::Registry.detect_for_read(path_or_io, strict: strict, filename: filename)
      options = normalize_codec_options!(codec_options)
      return codec.metadata(path_or_io, format: format, **options) if codec == Codecs::Raw

      metadata = codec.metadata(path_or_io, **options)
      return metadata unless format
      raise InvalidParameterError, "format must be Core::Format" unless format.is_a?(Core::Format)

      project_metadata(metadata, format)
    end

    singleton_class.alias_method :info, :metadata

    def self.project_metadata(metadata, target_format)
      source_format = metadata.fetch(:format)
      projected_frames = project_frame_count(
        metadata.fetch(:sample_frame_count),
        source_format.sample_rate,
        target_format.sample_rate
      )
      projected = metadata.merge(
        format: target_format,
        sample_frame_count: projected_frames,
        duration: Core::Duration.from_samples(projected_frames, target_format.sample_rate)
      )
      project_sample_coordinates!(projected, source_format.sample_rate, target_format.sample_rate)
    end
    private_class_method :project_metadata

    def self.project_sample_coordinates!(metadata, source_rate, target_rate)
      projector = ->(frame) { project_frame_count(frame, source_rate, target_rate) }
      metadata[:fact_sample_length] = projector.call(metadata[:fact_sample_length]) if metadata[:fact_sample_length]
      metadata[:loops] = project_loops(metadata[:loops], projector) if metadata[:loops]
      metadata[:cue_points] = project_cue_points(metadata[:cue_points], projector) if metadata[:cue_points]
      metadata[:smpl] = project_smpl(metadata[:smpl], projector, target_rate) if metadata[:smpl]
      metadata[:cue] = metadata[:cue].merge(points: metadata[:cue_points]) if metadata[:cue]
      if metadata[:bext]
        metadata[:bext] = metadata[:bext].merge(time_reference: projector.call(metadata[:bext].fetch(:time_reference)))
        metadata[:broadcast_extension] = metadata[:bext]
      end
      metadata
    end
    private_class_method :project_sample_coordinates!

    def self.project_frame_count(frame_count, source_rate, target_rate)
      (Rational(frame_count) * Rational(target_rate, source_rate)).round
    end
    private_class_method :project_frame_count

    def self.project_loops(loops, projector)
      loops.map do |loop|
        start_frame = projector.call(loop.fetch(:start_frame))
        end_frame = projector.call(loop.fetch(:end_frame) + 1) - 1
        end_frame = start_frame if end_frame < start_frame
        loop.merge(start_frame: start_frame, end_frame: end_frame, length_frames: end_frame - start_frame + 1)
      end
    end
    private_class_method :project_loops

    def self.project_cue_points(cue_points, projector)
      cue_points.map do |point|
        point.merge(
          position: projector.call(point.fetch(:position)),
          sample_offset: projector.call(point.fetch(:sample_offset))
        )
      end
    end
    private_class_method :project_cue_points

    def self.project_smpl(smpl, projector, target_rate)
      loops = smpl.fetch(:loops).map do |loop|
        start_frame = projector.call(loop.fetch(:start_frame))
        end_frame = projector.call(loop.fetch(:end_frame) + 1) - 1
        loop.merge(
          start_frame: start_frame,
          end_frame: [end_frame, start_frame].max
        )
      end
      smpl.merge(sample_period: (1_000_000_000.0 / target_rate).round, loops: loops)
    end
    private_class_method :project_smpl

    # Mixes multiple audio objects using a selectable clipping policy.
    #
    # @param audios [Array<Audio>]
    # @param strategy [Symbol] `:clip`, `:normalize`, `:headroom`, or `:soft_limit`
    # @param gains [Array<Numeric>, nil] optional per-source gain in dB
    # @param align [Symbol] `:start`, `:center`, or `:end`
    # @param headroom_smoothing [Numeric] seconds of gain smoothing around peaks
    # @return [Audio]
    def self.mix(*audios, strategy: :clip, gains: nil, align: :start, format: nil, work_format: nil,
                 headroom_smoothing: DSP::Headroom::DEFAULT_SMOOTHING_SECONDS)
      raise InvalidParameterError, "at least one Audio is required" if audios.empty?
      raise InvalidParameterError, "all arguments must be Audio instances" unless audios.all? { |audio| audio.is_a?(self) }

      mix_strategy = normalize_mix_strategy!(strategy)
      mix_gains = normalize_mix_gains!(gains, audios.length)
      mix_alignment = normalize_mix_alignment!(align)
      target_format = format || audios.first.format
      raise InvalidParameterError, "format must be Core::Format" unless target_format.is_a?(Core::Format)
      if work_format && !work_format.is_a?(Core::Format)
        raise InvalidParameterError, "work_format must be Core::Format"
      end
      if !format && !work_format && audios.map { |audio| audio.format.sample_rate }.uniq.length > 1
        raise InvalidParameterError, "different sample rates require an explicit format or work_format"
      end

      workspace_format = work_format || target_format.with(sample_format: :float, bit_depth: 32)
      workspace_format = workspace_format.with(sample_format: :float, bit_depth: 32)
      converted = audios.map { |audio| audio.buffer.convert(workspace_format) }
      max_frames = converted.map(&:sample_frame_count).max || 0
      channels = workspace_format.channels
      mixed = Array.new(max_frames * channels, 0.0)

      converted.each_with_index do |buffer, audio_index|
        gain_factor = db_to_amplitude(mix_gains.fetch(audio_index))
        sample_offset = mix_alignment_offset(mix_alignment, max_frames, buffer.sample_frame_count) * channels
        buffer.samples.each_with_index do |sample, index|
          target_index = sample_offset + index
          mixed[target_index] += sample * gain_factor
        end
      end

      apply_mix_strategy!(mixed, mix_strategy, format: workspace_format, headroom_smoothing: headroom_smoothing)
      new(Core::SampleBuffer.new(mixed, workspace_format).convert(target_format))
    end

    # Creates a streaming processing pipeline for an input path/IO.
    #
    # @param path_or_io [String, IO]
    # @param chunk_size [Integer] chunk size in frames
    # @param format [Core::Format, nil] optional source format override
    # @param codec_options [Hash] codec-specific options forwarded to `.stream_read`
    # @param strict [Boolean] verify extension and magic-byte codec agreement
    # @param filename [String, nil] optional filename hint for IO inputs
    # @return [Core::Stream]
    def self.stream(path_or_io, chunk_size: 4096, format: nil, codec_options: nil, strict: false, filename: nil)
      codec = Codecs::Registry.detect_for_read(path_or_io, strict: strict, filename: filename)
      options = normalize_codec_options!(codec_options)
      source_format = format
      if codec == Codecs::Raw && !source_format.is_a?(Core::Format)
        raise InvalidFormatError, "format is required for raw stream input"
      end
      options = options.merge(format: source_format) if codec == Codecs::Raw

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
    # @param waveform [Symbol] `:sine`, `:square`, `:triangle`, `:sawtooth`, `:pulse`, `:white_noise`
    # @return [Audio]
    def self.tone(frequency:, duration:, format:, waveform: :sine, **oscillator_options)
      oscillator = DSP::Oscillator.new(
        waveform: waveform,
        frequency: frequency,
        **oscillator_options
      )
      new(oscillator.generate(duration, format: format))
    end

    # Builds silent audio in the requested format.
    #
    # @param duration_seconds [Numeric]
    # @param format [Core::Format]
    # @return [Audio]
    def self.silence(duration_seconds, format:)
      seconds = duration_seconds.is_a?(Core::Duration) ? duration_seconds.total_seconds : duration_seconds
      unless seconds.is_a?(Numeric) && seconds.respond_to?(:finite?) && seconds.finite? && seconds >= 0
        raise InvalidParameterError, "duration_seconds must be a non-negative finite Numeric or Core::Duration: #{duration_seconds.inspect}"
      end
      raise InvalidParameterError, "format must be Core::Format" unless format.is_a?(Core::Format)

      frame_count = (seconds.to_f * format.sample_rate).round
      default_sample = format.sample_format == :float ? 0.0 : 0
      samples = Array.new(frame_count * format.channels, default_sample)
      new(Core::SampleBuffer.new(samples, format))
    end

    # @param buffer [Core::SampleBuffer]
    def initialize(buffer)
      raise InvalidParameterError, "buffer must be Core::SampleBuffer" unless buffer.is_a?(Core::SampleBuffer)

      @buffer = buffer
    end

    # Value equality based on the underlying immutable sample buffer.
    def ==(other)
      other.is_a?(Audio) && @buffer == other.buffer
    end

    alias eql? ==

    def hash
      @buffer.hash
    end

    # Writes the audio to a file path using codec auto-detection.
    #
    # @param path [String, IO]
    # @param format [Core::Format, nil] optional output format
    # @param codec_options [Hash] codec-specific options forwarded to `.write`
    # @param codec [Symbol, Class, nil] explicit output codec for generic IO targets
    # @param filename [String, nil] filename hint used for codec selection
    # @param overwrite [Boolean] whether existing path output may be replaced
    # @return [Audio] self
    def write(path, format: nil, codec: nil, filename: nil, codec_options: nil, overwrite: true)
      validate_overwrite!(path, overwrite)
      output_codec = codec ? Codecs::Registry.resolve(codec) : Codecs::Registry.detect_for_write(path, filename: filename)
      options = normalize_codec_options!(codec_options)
      with_output_target(path, overwrite: overwrite) do |target|
        output_codec.write(target, @buffer, format: format || @buffer.format, **options)
      end
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

    # @return [Integer]
    def channels
      format.channels
    end

    # @return [Integer]
    def sample_rate
      format.sample_rate
    end

    # @return [Integer]
    def bit_depth
      format.bit_depth
    end

    # Converts to another bit depth while keeping the remaining format fields.
    def with_bit_depth(value, dither: false, dither_seed: nil)
      convert(format.with(bit_depth: value), dither: dither, dither_seed: dither_seed)
    end

    # @return [Array<Array<Numeric>>] sample frames
    def frames
      @buffer.frame_view.to_a
    end

    # Enumerates sample frames.
    #
    # @yield [frame, frame_index]
    # @yieldparam frame [Array<Numeric>]
    # @yieldparam frame_index [Integer]
    # @return [Enumerator, Audio]
    def each_frame
      return enum_for(:each_frame) unless block_given?

      @buffer.frame_view.each.with_index do |frame, frame_index|
        yield frame, frame_index
      end
      self
    end

    # Converts to a new format/channels.
    #
    # @param new_format [Core::Format]
    # @param dither [Boolean] add TPDF dither when converting to PCM
    # @param dither_seed [Integer, nil] deterministic seed for dither noise
    # @return [Audio]
    def convert(new_format, dither: false, dither_seed: nil, resampler: :linear)
      self.class.new(@buffer.convert(new_format, dither: dither, dither_seed: dither_seed, resampler: resampler))
    end

    # Converts to another sample rate.
    #
    # @param sample_rate [Integer]
    # @return [Audio]
    def resample(sample_rate:, resampler: :linear)
      convert(format.with(sample_rate: sample_rate), resampler: resampler)
    end

    # Converts to mono by downmixing channels.
    #
    # @return [Audio]
    def to_mono
      convert(format.with(channels: 1))
    end

    # Converts to stereo by upmixing/downmixing channels.
    #
    # @return [Audio]
    def to_stereo
      convert(format.with(channels: 2))
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

    # Slices audio between two time offsets.
    #
    # @param from [Numeric, Core::Duration]
    # @param to [Numeric, Core::Duration]
    # @return [Audio]
    def slice(from:, to:)
      start_frame = coerce_time_to_frame(from, upper_bound: @buffer.sample_frame_count)
      end_frame = coerce_time_to_frame(to, upper_bound: @buffer.sample_frame_count)
      raise InvalidParameterError, "to must be greater than or equal to from" if end_frame < start_frame

      self.class.new(@buffer.slice(start_frame, end_frame - start_frame))
    end

    # Crops audio from a start time for a duration.
    #
    # @param start [Numeric, Core::Duration]
    # @param duration [Numeric, Core::Duration]
    # @return [Audio]
    def crop(start:, duration:)
      start_frame = coerce_time_to_frame(start, upper_bound: @buffer.sample_frame_count)
      frame_length = coerce_duration_to_frame(duration)
      self.class.new(@buffer.slice(start_frame, [frame_length, @buffer.sample_frame_count - start_frame].min))
    end

    # Concatenates another audio clip after this one.
    #
    # @param other [Audio]
    # @return [Audio]
    def concat(other)
      validate_audio!(other, :other)
      self.class.new(@buffer.concat(other.buffer))
    end

    alias append concat
    alias + concat

    # Prepends another audio clip before this one.
    #
    # @param other [Audio]
    # @return [Audio]
    def prepend(other)
      validate_audio!(other, :other)
      other.concat(self)
    end

    # Overlays another audio clip at a time offset.
    #
    # @param other [Audio]
    # @param at [Numeric, Core::Duration]
    # @param strategy [Symbol] mix clipping policy
    # @param headroom_smoothing [Numeric] seconds of gain smoothing around peaks
    # @return [Audio]
    def overlay(other, at:, strategy: :clip, headroom_smoothing: DSP::Headroom::DEFAULT_SMOOTHING_SECONDS)
      validate_audio!(other, :other)
      start_frame = coerce_time_to_frame(at, upper_bound: nil)
      work_format = float_work_format(format)
      base = @buffer.convert(work_format)
      overlay_buffer = other.buffer.convert(work_format)
      channels = work_format.channels
      mixed_length = [base.samples.length, (start_frame * channels) + overlay_buffer.samples.length].max
      mixed = Array.new(mixed_length, 0.0)
      base.samples.each_with_index do |sample, index|
        mixed[index] += sample
      end
      offset = start_frame * channels
      overlay_buffer.samples.each_with_index do |sample, index|
        target_index = offset + index
        mixed[target_index] += sample
      end

      self.class.send(
        :apply_mix_strategy!,
        mixed,
        self.class.send(:normalize_mix_strategy!, strategy),
        format: work_format,
        headroom_smoothing: headroom_smoothing
      )
      self.class.new(Core::SampleBuffer.new(mixed, work_format).convert(format))
    end

    # Crossfades this audio into another clip.
    #
    # @param other [Audio]
    # @param duration [Numeric, Core::Duration]
    # @return [Audio]
    def crossfade(other, duration:)
      validate_audio!(other, :other)
      rhs = other.convert(format)
      overlap_frames = coerce_duration_to_frame(duration)
      max_overlap = [sample_frame_count, rhs.sample_frame_count].min
      raise InvalidParameterError, "duration is longer than one of the clips" if overlap_frames > max_overlap

      seconds = overlap_frames.to_f / sample_rate
      left_head = self.class.new(@buffer.slice(0, sample_frame_count - overlap_frames))
      left_tail = self.class.new(@buffer.slice(sample_frame_count - overlap_frames, overlap_frames)).fade_out(seconds)
      right_head = self.class.new(rhs.buffer.slice(0, overlap_frames)).fade_in(seconds)
      right_tail = self.class.new(rhs.buffer.slice(overlap_frames, rhs.sample_frame_count - overlap_frames))
      middle = self.class.mix(left_tail, right_head, strategy: :clip)

      left_head.concat(middle).concat(right_tail)
    end

    # Adds silence before the audio.
    #
    # @param seconds [Numeric, Core::Duration]
    # @return [Audio]
    def pad_start(seconds)
      self.class.silence(coerce_seconds(seconds), format: format).concat(self)
    end

    # Adds silence after the audio.
    #
    # @param seconds [Numeric, Core::Duration]
    # @return [Audio]
    def pad_end(seconds)
      concat(self.class.silence(coerce_seconds(seconds), format: format))
    end

    # Inserts silence at a time offset.
    #
    # @param at [Numeric, Core::Duration]
    # @param duration [Numeric, Core::Duration]
    # @return [Audio]
    def insert_silence(at:, duration:)
      left, right = split(at: at)
      left.concat(self.class.silence(coerce_seconds(duration), format: format)).concat(right)
    end

    # Repeats the audio content.
    #
    # @param times [Integer] repetition count
    # @return [Audio]
    def repeat(times:)
      raise InvalidParameterError, "times must be a non-negative Integer" unless times.is_a?(Integer) && times >= 0

      return self.class.new(Core::SampleBuffer.new([], @buffer.format)) if times.zero?

      repeated_frames = sample_frame_count * times
      repeated_bytes = repeated_frames * format.block_align
      if repeated_frames > MAX_REPEAT_FRAMES || repeated_bytes > MAX_REPEAT_BYTES
        raise InvalidParameterError,
              "repeat output exceeds limits (#{repeated_frames} frames, #{repeated_bytes} bytes); use #repeat_chunks"
      end

      self.class.new(Core::SampleBuffer.new(@buffer.samples * times, @buffer.format))
    end

    # Lazily yields repeated audio in bounded chunks.
    def repeat_chunks(times:, chunk_frames: 4_096)
      raise InvalidParameterError, "times must be a non-negative Integer" unless times.is_a?(Integer) && times >= 0
      unless chunk_frames.is_a?(Integer) && chunk_frames.positive?
        raise InvalidParameterError, "chunk_frames must be a positive Integer"
      end

      Enumerator.new do |yielder|
        times.times do
          offset = 0
          while offset < sample_frame_count
            length = [chunk_frames, sample_frame_count - offset].min
            yielder << @buffer.slice(offset, length)
            offset += length
          end
        end
      end
    end

    # In-place variant of {#repeat}.
    #
    # @param times [Integer]
    # @return [Audio] self
    def repeat!(times:)
      replace_buffer!(repeat(times: times).buffer)
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
      db = validate_finite_numeric!(db, :db)
      factor = 10.0**(db / 20.0)
      transform_samples do |samples, _format|
        samples.map! { |sample| sample * factor }
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
    def normalize(target_db: 0.0, mode: :peak)
      normalize_mode = self.class.send(:normalize_mode!, mode)
      unless target_db.is_a?(Numeric) && target_db.respond_to?(:finite?) && target_db.finite?
        raise InvalidParameterError, "target_db must be a finite Numeric"
      end
      if normalize_mode == :peak && target_db.positive?
        raise InvalidParameterError, "peak target_db must be <= 0 dBFS"
      end

      transform_samples do |samples, work_format|
        if normalize_mode == :lufs
          current_lufs = integrated_loudness(samples, work_format)
          next samples unless current_lufs.finite?

          factor = 10.0**((target_db.to_f - current_lufs) / 20.0)
          next samples.map! { |sample| sample * factor }
        end

        current = normalize_reference_amplitude(samples, normalize_mode)
        next samples if current.zero?

        target = 10.0**(target_db.to_f / 20.0)
        factor = target / current
        samples.map! { |sample| sample * factor }
      end
    end

    # In-place variant of {#normalize}.
    #
    # @param target_db [Numeric]
    # @return [Audio] self
    def normalize!(target_db: 0.0, mode: :peak)
      replace_buffer!(normalize(target_db: target_db, mode: mode).buffer)
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
      first = nil
      last = nil
      float_buffer.samples.each_slice(channels).with_index do |frame, frame_index|
        next unless frame.any? { |sample| sample.abs >= threshold }

        first ||= frame_index
        last = frame_index
      end
      return self.class.new(Core::SampleBuffer.new([], @buffer.format)) unless first

      float_trimmed = float_buffer.slice(first, last - first + 1)
      self.class.new(float_trimmed.convert(@buffer.format))
    end

    # In-place variant of {#trim}.
    #
    # @param threshold [Numeric]
    # @return [Audio] self
    def trim!(threshold: 0.01)
      replace_buffer!(trim(threshold: threshold).buffer)
      self
    end

    # Applies a fade-in.
    #
    # @param seconds [Numeric, Core::Duration]
    # @param curve [Symbol] `:linear`, `:exp`, or `:log`
    # @return [Audio]
    def fade_in(seconds, curve: :linear)
      apply_fade(seconds: seconds, mode: :in, curve: curve)
    end

    # In-place variant of {#fade_in}.
    #
    # @param seconds [Numeric, Core::Duration]
    # @param curve [Symbol]
    # @return [Audio] self
    def fade_in!(seconds, curve: :linear)
      replace_buffer!(fade_in(seconds, curve: curve).buffer)
      self
    end

    # Applies a fade-out.
    #
    # @param seconds [Numeric, Core::Duration]
    # @param curve [Symbol] `:linear`, `:exp`, or `:log`
    # @return [Audio]
    def fade_out(seconds, curve: :linear)
      apply_fade(seconds: seconds, mode: :out, curve: curve)
    end

    # In-place variant of {#fade_out}.
    #
    # @param seconds [Numeric, Core::Duration]
    # @param curve [Symbol]
    # @return [Audio] self
    def fade_out!(seconds, curve: :linear)
      replace_buffer!(fade_out(seconds, curve: curve).buffer)
      self
    end

    # Applies a fade in either direction.
    #
    # @param seconds [Numeric, Core::Duration]
    # @param type [Symbol] `:in` or `:out`
    # @param curve [Symbol] `:linear`, `:exp`, or `:log`
    # @return [Audio]
    def fade(seconds, type:, curve: :linear)
      apply_fade(seconds: seconds, mode: type, curve: curve)
    end

    # Constant-power pan for a mono source.
    #
    # @param position [Numeric] `-1.0` (left) to `1.0` (right)
    # @return [Audio]
    def pan(position)
      validate_pan_position!(position)
      raise InvalidParameterError, "pan requires mono input; use #balance for stereo" unless @buffer.format.channels == 1

      source_format = @buffer.format.with(channels: 2)

      transform_samples(target_format: source_format) do |samples, _format|
        left_gain, right_gain = constant_power_pan_gains(position.to_f)
        samples.each_slice(2).with_index do |(left, right), frame_index|
          base = frame_index * 2
          samples[base] = left * left_gain
          samples[base + 1] = right * right_gain
        end
        samples
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

    # Adjusts the relative level of existing stereo channels without moving content between them.
    def balance(position)
      validate_pan_position!(position)
      raise InvalidParameterError, "balance requires stereo input" unless channels == 2

      transform_samples do |samples, _format|
        left_gain = position.positive? ? Math.cos(position * Math::PI / 2.0) : 1.0
        right_gain = position.negative? ? Math.cos(position.abs * Math::PI / 2.0) : 1.0
        samples.each_slice(2).with_index do |(left, right), frame_index|
          base = frame_index * 2
          samples[base] = left * left_gain
          samples[base + 1] = right * right_gain
        end
        samples
      end
    end

    # Rotates a stereo image, transferring energy between left and right.
    def stereo_rotate(position)
      validate_pan_position!(position)
      raise InvalidParameterError, "stereo_rotate requires stereo input" unless channels == 2

      angle = position * Math::PI / 4.0
      cosine = Math.cos(angle)
      sine = Math.sin(angle)
      transform_samples do |samples, _format|
        samples.each_slice(2).with_index do |(left, right), frame_index|
          base = frame_index * 2
          samples[base] = (left * cosine) - (right * sine)
          samples[base + 1] = (left * sine) + (right * cosine)
        end
        samples
      end
    end

    # Applies an effect/processor object to the audio buffer.
    #
    # Accepted interfaces: `#process`, `#call`, or `#apply`.
    #
    # @param effect [Object]
    # @return [Audio]
    def apply(effect)
      processed = DSP::Processor.render(effect, @buffer)

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

    # Maps normalized float samples and returns a new audio object in the original format.
    #
    # @yield [sample, sample_index]
    # @yieldparam sample [Float]
    # @yieldparam sample_index [Integer]
    # @return [Enumerator, Audio]
    def map_samples
      return enum_for(:map_samples) unless block_given?

      transform_samples do |samples, _format|
        samples.map!.with_index do |sample, sample_index|
          validate_mapped_sample!(yield(sample, sample_index), "sample #{sample_index}")
        end
      end
    end

    # Maps normalized float frames and returns a new audio object in the original format.
    #
    # @yield [frame, frame_index]
    # @yieldparam frame [Array<Float>]
    # @yieldparam frame_index [Integer]
    # @return [Enumerator, Audio]
    def map_frames
      return enum_for(:map_frames) unless block_given?

      transform_samples do |samples, work_format|
        mapped = []
        samples.each_slice(work_format.channels).with_index do |frame, frame_index|
          output = yield(frame.dup, frame_index)
          unless output.is_a?(Array) && output.length == work_format.channels
            raise InvalidParameterError, "map_frames block must return an Array with #{work_format.channels} samples"
          end

          mapped.concat(output.map.with_index do |sample, channel_index|
            validate_mapped_sample!(sample, "frame #{frame_index}, channel #{channel_index}")
          end)
        end
        mapped
      end
    end

    # Returns the absolute peak amplitude in float working space.
    #
    # @return [Float] 0.0..1.0
    def sample_peak_amplitude
      float_buffer = @buffer.convert(float_work_format(@buffer.format))
      float_buffer.samples.map(&:abs).max || 0.0
    end


    alias peak_amplitude sample_peak_amplitude

    # Returns oversampled inter-sample peak amplitude.
    def true_peak_amplitude(oversampling: DSP::LoudnessMeter::TRUE_PEAK_OVERSAMPLING)
      float_buffer = @buffer.convert(float_work_format(@buffer.format))
      DSP::LoudnessMeter.true_peak(float_buffer, format: float_buffer.format, oversampling: oversampling)
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

    # @return [Float] peak amplitude in dBFS
    def peak_dbfs
      sample_peak_dbfs
    end

    def sample_peak_dbfs
      amplitude_to_dbfs(sample_peak_amplitude)
    end

    def true_peak_dbfs(oversampling: DSP::LoudnessMeter::TRUE_PEAK_OVERSAMPLING)
      amplitude_to_dbfs(true_peak_amplitude(oversampling: oversampling))
    end

    # @return [Float] RMS amplitude in dBFS
    def rms_dbfs
      amplitude_to_dbfs(rms_amplitude)
    end

    # @return [Float] BS.1770 integrated loudness in LUFS
    def lufs
      float_buffer = @buffer.convert(float_work_format(@buffer.format))
      integrated_loudness(float_buffer.samples, float_buffer.format)
    end

    # @return [Hash] basic audio statistics
    def stats
      float_buffer = @buffer.convert(float_work_format(@buffer.format))
      samples = float_buffer.samples
      accumulated = accumulate_statistics(samples, float_buffer.format.channels, consecutive_frames: 2)
      peak = accumulated.fetch(:peak)
      rms = accumulated.fetch(:rms)
      true_peak = DSP::LoudnessMeter.true_peak(float_buffer, format: float_buffer.format)
      {
        format: format,
        duration: duration,
        sample_frame_count: sample_frame_count,
        peak_amplitude: peak,
        sample_peak_amplitude: peak,
        true_peak_amplitude: true_peak,
        rms_amplitude: rms,
        peak_dbfs: amplitude_to_dbfs(peak),
        sample_peak_dbfs: amplitude_to_dbfs(peak),
        true_peak_dbfs: amplitude_to_dbfs(true_peak),
        rms_dbfs: amplitude_to_dbfs(rms),
        lufs: integrated_loudness(samples, float_buffer.format),
        clipped: accumulated.fetch(:clipped),
        silent: peak.zero?,
        dc_offsets: accumulated.fetch(:dc_offsets),
        zero_crossing_rate: accumulated.fetch(:zero_crossing_rate)
      }
    end

    # @param threshold [Numeric]
    # @return [Boolean]
    def silent?(threshold: 0.0)
      raise InvalidParameterError, "threshold must be Numeric in 0.0..1.0" unless threshold.is_a?(Numeric) && threshold.between?(0.0, 1.0)

      peak_amplitude <= threshold
    end

    # Detects likely digital clipping by looking for consecutive full-scale
    # samples on the same channel. A single legal full-scale PCM sample is not
    # sufficient evidence that the source was clipped.
    #
    # @param consecutive_frames [Integer] full-scale frames required per channel
    # @return [Boolean]
    def clipped?(consecutive_frames: 2)
      unless consecutive_frames.is_a?(Integer) && consecutive_frames.positive?
        raise InvalidParameterError, "consecutive_frames must be a positive Integer"
      end

      float_buffer = @buffer.convert(float_work_format(@buffer.format))
      clipped_samples?(float_buffer.samples, float_buffer.format.channels, consecutive_frames: consecutive_frames)
    end

    # @return [Float] average sample offset in normalized float space
    def dc_offset
      float_buffer = @buffer.convert(float_work_format(@buffer.format))
      return 0.0 if float_buffer.samples.empty?

      float_buffer.samples.sum / float_buffer.samples.length.to_f
    end

    # Returns the mean offset for each channel.
    def dc_offsets
      float_buffer = @buffer.convert(float_work_format(@buffer.format))
      channels = float_buffer.format.channels
      return Array.new(channels, 0.0) if float_buffer.sample_frame_count.zero?

      sums = Array.new(channels, 0.0)
      float_buffer.each_frame_sample { |sample, _frame, channel| sums[channel] += sample }
      sums.map { |sum| sum / float_buffer.sample_frame_count.to_f }
    end

    # @return [Audio]
    def remove_dc_offset
      offsets = dc_offsets
      map_samples { |sample, index| sample - offsets.fetch(index % channels) }
    end

    # @return [Float] zero-crossing rate per channel stream
    def zero_crossing_rate
      float_buffer = @buffer.convert(float_work_format(@buffer.format))
      channels = float_buffer.format.channels
      return 0.0 if float_buffer.sample_frame_count <= 1

      crossings = 0
      comparisons = 0
      channels.times do |channel|
        previous = nil
        float_buffer.samples.each_slice(channels) do |frame|
          current = frame.fetch(channel)
          if previous
            crossings += 1 if (previous.negative? && current >= 0.0) || (previous >= 0.0 && current.negative?)
            comparisons += 1
          end
          previous = current
        end
      end
      return 0.0 if comparisons.zero?

      crossings.to_f / comparisons
    end

    # @return [String]
    def inspect
      "#<#{self.class.name} #{human_sample_rate} #{human_channels} #{format.bit_depth}-bit #{format.sample_format} #{Kernel.format('%.3fs', duration.total_seconds)}>"
    end

    private

    def accumulate_statistics(samples, channels, consecutive_frames:)
      peak = 0.0
      square_sum = 0.0
      channel_sums = Array.new(channels, 0.0)
      previous = Array.new(channels)
      crossings = 0
      comparisons = 0
      clipped_states = Array.new(channels) { { polarity: nil, count: 0 } }
      clipped = false

      samples.each_with_index do |sample, index|
        channel = index % channels
        absolute = sample.abs
        peak = absolute if absolute > peak
        square_sum += sample * sample
        channel_sums[channel] += sample
        prior = previous[channel]
        if prior
          crossings += 1 if (prior.negative? && sample >= 0.0) || (prior >= 0.0 && sample.negative?)
          comparisons += 1
        end
        previous[channel] = sample

        state = clipped_states.fetch(channel)
        polarity = sample <= -1.0 ? -1 : (1 if sample >= 1.0)
        if polarity
          state[:count] = state[:polarity] == polarity ? state[:count] + 1 : 1
          state[:polarity] = polarity
          clipped ||= state[:count] >= consecutive_frames
        else
          state[:polarity] = nil
          state[:count] = 0
        end
      end
      frames = samples.length / channels
      {
        peak: peak,
        rms: samples.empty? ? 0.0 : Math.sqrt(square_sum / samples.length),
        dc_offsets: frames.zero? ? Array.new(channels, 0.0) : channel_sums.map { |sum| sum / frames.to_f },
        zero_crossing_rate: comparisons.zero? ? 0.0 : crossings.to_f / comparisons,
        clipped: clipped
      }
    end

    def clipped_samples?(samples, channels, consecutive_frames:)
      clipped_channels = Array.new(channels) { { polarity: nil, count: 0 } }

      samples.each_slice(channels) do |frame|
        frame.each_with_index do |sample, channel|
          state = clipped_channels.fetch(channel)
          polarity = sample <= -1.0 ? -1 : (1 if sample >= 1.0)
          unless polarity
            state[:polarity] = nil
            state[:count] = 0
            next
          end

          state[:count] = state[:polarity] == polarity ? state[:count] + 1 : 1
          state[:polarity] = polarity
          return true if state[:count] >= consecutive_frames
        end
      end

      false
    end

    def self.normalize_codec_options!(codec_options)
      return {} if codec_options.nil?
      raise InvalidParameterError, "codec_options must be a Hash" unless codec_options.is_a?(Hash)

      invalid_keys = codec_options.keys.reject { |key| key.is_a?(Symbol) }
      unless invalid_keys.empty?
        raise InvalidParameterError, "codec_options keys must be Symbols: #{invalid_keys.map(&:inspect).join(', ')}"
      end

      codec_options.dup
    end
    private_class_method :normalize_codec_options!

    def normalize_codec_options!(codec_options)
      self.class.send(:normalize_codec_options!, codec_options)
    end

    def validate_overwrite!(path, overwrite)
      raise InvalidParameterError, "overwrite must be true or false" unless overwrite == true || overwrite == false
    end

    def with_output_target(path, overwrite:)
      return yield(path) unless path.is_a?(String)

      expanded_path = File.expand_path(path)
      temporary = Tempfile.new([".wavify-", File.extname(path)], File.dirname(expanded_path), binmode: true)
      yield temporary
      temporary.flush
      temporary.fsync
      temporary.close
      if overwrite
        File.rename(temporary.path, expanded_path)
      else
        File.link(temporary.path, expanded_path)
        File.unlink(temporary.path)
      end
    rescue Errno::EEXIST
      raise InvalidParameterError, "output file already exists: #{path}"
    ensure
      temporary&.close!
    end

    def validate_audio!(audio, name)
      raise InvalidParameterError, "#{name} must be Audio" unless audio.is_a?(self.class)
    end

    def coerce_seconds(value)
      seconds = case value
                when Core::Duration
                  value.total_seconds
                when Numeric
                  value.to_f
                else
                  raise InvalidParameterError, "time value must be Numeric or Core::Duration"
                end
      unless seconds.respond_to?(:finite?) && seconds.finite? && seconds >= 0.0
        raise InvalidParameterError, "time value must be a non-negative finite Numeric"
      end

      seconds
    end

    def coerce_time_to_frame(value, upper_bound:)
      frame = (coerce_seconds(value) * @buffer.format.sample_rate).round
      if upper_bound && frame > upper_bound
        raise InvalidParameterError, "time value is out of range: #{frame}"
      end

      frame
    end

    def coerce_duration_to_frame(value)
      (coerce_seconds(value) * @buffer.format.sample_rate).round
    end

    def amplitude_to_dbfs(amplitude)
      return -Float::INFINITY if amplitude <= 0.0

      20.0 * Math.log10(amplitude)
    end

    def normalize_reference_amplitude(samples, mode)
      case mode
      when :peak
        samples.map(&:abs).max || 0.0
      when :rms
        return 0.0 if samples.empty?

        Math.sqrt(samples.sum { |sample| sample * sample } / samples.length)
      end
    end

    def integrated_loudness(samples, format)
      DSP::LoudnessMeter.integrated(
        samples,
        format: format
      )
    end

    def human_sample_rate
      if sample_rate >= 1000
        "#{(sample_rate / 1000.0).round(1)}kHz"
      else
        "#{sample_rate}Hz"
      end
    end

    def human_channels
      case channels
      when 1 then "mono"
      when 2 then "stereo"
      else "#{channels}ch"
      end
    end

    def apply_fade(seconds:, mode:, curve:)
      fade_seconds = coerce_seconds(seconds)
      fade_mode = self.class.send(:normalize_fade_mode!, mode)
      fade_curve = self.class.send(:normalize_fade_curve!, curve)

      transform_samples do |samples, format|
        channels = format.channels
        sample_frames = samples.length / channels
        fade_frames = [(fade_seconds * format.sample_rate).round, sample_frames].min
        next samples if fade_frames.zero?

        start_frame = sample_frames - fade_frames

        samples.each_slice(channels).with_index do |frame, frame_index|
          factor = fade_factor_for(
            frame_index,
            fade_frames: fade_frames,
            sample_frames: sample_frames,
            start_frame: start_frame,
            mode: fade_mode,
            curve: fade_curve
          )
          base = frame_index * channels
          frame.each_index do |channel_index|
            samples[base + channel_index] = frame[channel_index] * factor
          end
        end

        samples
      end
    end

    def fade_factor_for(frame_index, fade_frames:, sample_frames:, start_frame:, mode:, curve:)
      linear_factor = case mode
                      when :in
                        frame_index < fade_frames ? fade_endpoint_ratio(frame_index, fade_frames, single_frame: 1.0) : 1.0
                      when :out
                        if frame_index >= start_frame
                          fade_endpoint_ratio(sample_frames - frame_index - 1, fade_frames, single_frame: 0.0)
                        else
                          1.0
                        end
                      end

      fade_curve_factor(linear_factor.clamp(0.0, 1.0), curve)
    end

    def fade_curve_factor(value, curve)
      case curve
      when :linear
        value
      when :exp
        value * value
      when :log
        Math.log10(1.0 + (9.0 * value))
      end
    end

    def fade_endpoint_ratio(numerator, fade_frames, single_frame:)
      return single_frame if fade_frames == 1

      numerator.to_f / (fade_frames - 1)
    end

    def transform_samples(target_format: @buffer.format)
      raise InvalidParameterError, "target_format must be Core::Format" unless target_format.is_a?(Core::Format)

      work_format = float_work_format(target_format)
      workspace = Core::SampleBuffer::MutableFloatWorkspace.from_buffer(@buffer, format: work_format)
      transformed_samples = yield(workspace.samples, work_format)
      workspace.replace!(transformed_samples) unless transformed_samples.equal?(workspace.samples)
      processed = workspace.to_sample_buffer.convert(target_format)
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
      unless position.is_a?(Numeric) && position.respond_to?(:finite?) && position.finite? && position.between?(-1.0, 1.0)
        raise InvalidParameterError, "position must be a finite Numeric in -1.0..1.0"
      end
    end

    def validate_finite_numeric!(value, name)
      unless value.is_a?(Numeric) && value.respond_to?(:finite?) && value.finite?
        raise InvalidParameterError, "#{name} must be a finite Numeric"
      end

      value.to_f
    end

    def validate_mapped_sample!(value, location)
      unless value.is_a?(Numeric) && value.real? && value.respond_to?(:finite?) && value.finite?
        raise InvalidParameterError, "mapped #{location} must be a finite real Numeric"
      end

      value.to_f
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

    def self.normalize_mix_strategy!(strategy)
      normalized = strategy.to_sym if strategy.respond_to?(:to_sym)
      return normalized if MIX_STRATEGIES.include?(normalized)

      raise InvalidParameterError, "strategy must be one of: #{MIX_STRATEGIES.join(', ')}"
    end
    private_class_method :normalize_mix_strategy!

    def self.normalize_mix_alignment!(align)
      normalized = align.to_sym if align.respond_to?(:to_sym)
      return normalized if MIX_ALIGNMENTS.include?(normalized)

      raise InvalidParameterError, "align must be one of: #{MIX_ALIGNMENTS.join(', ')}"
    end
    private_class_method :normalize_mix_alignment!

    def self.normalize_mix_gains!(gains, source_count)
      return Array.new(source_count, 0.0) if gains.nil?
      raise InvalidParameterError, "gains must be an Array" unless gains.is_a?(Array)
      raise InvalidParameterError, "gains must have one value per Audio" unless gains.length == source_count

      gains.map do |gain|
        unless gain.is_a?(Numeric) && gain.respond_to?(:finite?) && gain.finite?
          raise InvalidParameterError, "gains must contain finite Numeric dB values"
        end

        gain.to_f
      end
    end
    private_class_method :normalize_mix_gains!

    def self.mix_alignment_offset(align, max_frames, frame_count)
      case align
      when :start
        0
      when :center
        ((max_frames - frame_count) / 2.0).round
      when :end
        max_frames - frame_count
      end
    end
    private_class_method :mix_alignment_offset

    def self.db_to_amplitude(db)
      10.0**(db / 20.0)
    end
    private_class_method :db_to_amplitude

    def self.normalize_mode!(mode)
      normalized = mode.to_sym if mode.respond_to?(:to_sym)
      return normalized if NORMALIZE_MODES.include?(normalized)

      raise InvalidParameterError, "mode must be one of: #{NORMALIZE_MODES.join(', ')}"
    end
    private_class_method :normalize_mode!

    def self.normalize_fade_mode!(mode)
      normalized = mode.to_sym if mode.respond_to?(:to_sym)
      return normalized if %i[in out].include?(normalized)

      raise InvalidParameterError, "fade type must be :in or :out"
    end
    private_class_method :normalize_fade_mode!

    def self.normalize_fade_curve!(curve)
      normalized = curve.to_sym if curve.respond_to?(:to_sym)
      return normalized if FADE_CURVES.include?(normalized)

      raise InvalidParameterError, "fade curve must be one of: #{FADE_CURVES.join(', ')}"
    end
    private_class_method :normalize_fade_curve!

    def self.apply_mix_strategy!(samples, strategy, format: nil, headroom_smoothing: DSP::Headroom::DEFAULT_SMOOTHING_SECONDS)
      case strategy
      when :none
        samples
      when :clip
        samples.map! { |sample| clip_value(sample, -1.0, 1.0) }
      when :normalize
        normalize_mix_samples!(samples)
      when :headroom
        DSP::Headroom.apply!(
          samples,
          channels: format&.channels || 1,
          sample_rate: format&.sample_rate || 1,
          smoothing_seconds: headroom_smoothing
        )
      when :soft_limit
        samples.map! { |sample| soft_limit_value(sample) }
      end
    end
    private_class_method :apply_mix_strategy!

    def self.normalize_mix_samples!(samples)
      peak = samples.map(&:abs).max || 0.0
      return samples if peak <= 1.0

      samples.map! { |sample| sample / peak }
    end
    private_class_method :normalize_mix_samples!

    def self.soft_limit_value(sample)
      value = sample.to_f
      magnitude = value.abs
      return value if magnitude <= SOFT_LIMIT_THRESHOLD

      range = 1.0 - SOFT_LIMIT_THRESHOLD
      sign = value.negative? ? -1.0 : 1.0
      limited = SOFT_LIMIT_THRESHOLD + (range * (1.0 - Math.exp(-(magnitude - SOFT_LIMIT_THRESHOLD) / range)))
      sign * clip_value(limited, 0.0, 1.0)
    end
    private_class_method :soft_limit_value
  end
end
