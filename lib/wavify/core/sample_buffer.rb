# frozen_string_literal: true

module Wavify
  module Core
    # Immutable interleaved sample container with format metadata.
    #
    # Samples are stored in interleaved order (`L, R, L, R, ...`) for
    # multi-channel audio. Packed buffers remain packed when enumerated,
    # compared, hashed, or converted to the same format without dither.
    # Random-access operations (`samples`, `frame_view`, `view`, `slice`,
    # `concat`, `reverse`, and format-changing `convert`) materialize them.
    # Hashing samples a fixed number of positions, so it is O(1); collisions
    # are resolved by full value equality, whose worst case is O(n).
    class SampleBuffer
      include Enumerable

      PACKED_ENUMERATION_CHUNK_SAMPLES = 4_096

      # Lazy no-copy view over interleaved samples as sample frames.
      class FrameView
        include Enumerable

        attr_reader :channels, :frame_count

        def initialize(samples, channels, start_frame: 0, frame_count: nil)
          raise InvalidParameterError, "samples must be an Array" unless samples.is_a?(Array)
          raise InvalidParameterError, "channels must be a positive Integer" unless channels.is_a?(Integer) && channels.positive?
          raise InvalidParameterError, "start_frame must be a non-negative Integer" unless start_frame.is_a?(Integer) && start_frame >= 0

          max_frames = samples.length / channels
          @samples = samples
          @channels = channels
          @start_frame = [start_frame, max_frames].min
          requested_count = frame_count.nil? ? max_frames - @start_frame : frame_count
          raise InvalidParameterError, "frame_count must be a non-negative Integer" unless requested_count.is_a?(Integer) && requested_count >= 0

          @frame_count = [requested_count, max_frames - @start_frame].min
        end

        def each
          return enum_for(:each) unless block_given?

          @frame_count.times { |index| yield self[index] }
        end

        def [](index)
          raise InvalidParameterError, "frame index must be an Integer" unless index.is_a?(Integer)

          normalized = index.negative? ? @frame_count + index : index
          return nil unless normalized.between?(0, @frame_count - 1)

          sample_index = (@start_frame + normalized) * @channels
          @samples.slice(sample_index, @channels).dup
        end

        def slice(start_frame, frame_length)
          unless start_frame.is_a?(Integer) && start_frame >= 0
            raise InvalidParameterError, "start_frame must be a non-negative Integer: #{start_frame.inspect}"
          end
          unless frame_length.is_a?(Integer) && frame_length >= 0
            raise InvalidParameterError, "frame_length must be a non-negative Integer: #{frame_length.inspect}"
          end

          self.class.new(@samples, @channels, start_frame: @start_frame + start_frame, frame_count: frame_length)
        end

        def length
          @frame_count
        end

        alias size length
      end

      # Lazy no-copy view over a contiguous frame range of a sample buffer.
      class View
        include Enumerable

        attr_reader :format, :duration

        def initialize(samples, format, start_frame: 0, frame_count: nil)
          raise InvalidParameterError, "samples must be an Array" unless samples.is_a?(Array)
          raise InvalidParameterError, "format must be Core::Format" unless format.is_a?(Format)
          raise InvalidParameterError, "start_frame must be a non-negative Integer" unless start_frame.is_a?(Integer) && start_frame >= 0

          max_frames = samples.length / format.channels
          @samples = samples
          @format = format
          @start_frame = [start_frame, max_frames].min
          requested_count = frame_count.nil? ? max_frames - @start_frame : frame_count
          raise InvalidParameterError, "frame_count must be a non-negative Integer" unless requested_count.is_a?(Integer) && requested_count >= 0

          @frame_count = [requested_count, max_frames - @start_frame].min
          @duration = Duration.from_samples(@frame_count, format.sample_rate)
        end

        # Enumerates interleaved sample values in the view range.
        #
        # @yieldparam sample [Numeric]
        # @return [Enumerator, Array<Numeric>]
        def each
          return enum_for(:each) unless block_given?

          start_index = @start_frame * @format.channels
          length.times { |offset| yield @samples.fetch(start_index + offset) }
        end

        # Materializes the view's interleaved samples.
        #
        # @return [Array<Numeric>]
        def samples
          start_index = @start_frame * @format.channels
          @samples.slice(start_index, length).freeze
        end

        # @return [Integer] number of interleaved samples in the view
        def length
          @frame_count * @format.channels
        end

        alias size length

        # @return [Integer] number of sample frames in the view
        def sample_frame_count
          @frame_count
        end

        # @return [FrameView]
        def frame_view
          FrameView.new(@samples, @format.channels, start_frame: @start_frame, frame_count: @frame_count)
        end

        # Returns another lazy view relative to this view.
        #
        # @param start_frame [Integer]
        # @param frame_length [Integer]
        # @return [View]
        def slice(start_frame, frame_length)
          unless start_frame.is_a?(Integer) && start_frame >= 0
            raise InvalidParameterError, "start_frame must be a non-negative Integer: #{start_frame.inspect}"
          end
          unless frame_length.is_a?(Integer) && frame_length >= 0
            raise InvalidParameterError, "frame_length must be a non-negative Integer: #{frame_length.inspect}"
          end

          self.class.new(@samples, @format, start_frame: @start_frame + start_frame, frame_count: frame_length)
        end

        # Materializes the view as an immutable sample buffer.
        #
        # @return [SampleBuffer]
        def to_sample_buffer
          SampleBuffer.new(samples, @format)
        end

        # Converts the materialized view to another format.
        #
        # @param new_format [Format]
        # @return [SampleBuffer]
        def convert(new_format, **options)
          to_sample_buffer.convert(new_format, **options)
        end
      end

      STORAGE_TYPES = %i[array packed].freeze
      HASH_PROBE_COUNT = 8
      StorageState = Struct.new(:samples, :packed_samples, :type, keyword_init: true) # :nodoc:

      attr_reader :format, :duration

      # @param samples [Array<Numeric>] interleaved sample values
      # @param format [Format] sample encoding and channel layout
      def initialize(samples, format, storage: :array)
        raise InvalidParameterError, "format must be Core::Format" unless format.is_a?(Format)
        raise InvalidParameterError, "samples must be an Array" unless samples.is_a?(Array)

        validate_samples!(samples)
        validate_interleaving!(samples.length, format.channels)
        storage = normalize_storage!(storage)

        @format = format
        coerced = coerce_samples(samples, format)
        @sample_count = coerced.length
        @value_hash = sample_value_hash(coerced, canonical_float: storage == :packed && format.sample_format == :float)
        @storage_mutex = Mutex.new
        @storage_state = if storage == :packed
                           storage_state(samples: nil, packed_samples: pack_samples(coerced, format).freeze, type: :packed)
                         else
                           storage_state(samples: coerced.freeze, packed_samples: nil, type: :array)
                         end
        @duration = Duration.from_samples(sample_frame_count, format.sample_rate)
      end

      # Materializes packed storage on first random-access use.
      def samples
        state = @storage_state
        return state.samples if state.samples

        @storage_mutex.synchronize do
          state = @storage_state
          return state.samples if state.samples

          materialized = unpack_samples(state.packed_samples, @format).freeze
          @storage_state = storage_state(samples: materialized, packed_samples: nil, type: :array)
        end
        @storage_state.samples
      end

      def storage
        @storage_state.type
      end

      def packed?
        @storage_state.type == :packed
      end

      def packed_bytesize
        @storage_state.packed_samples&.bytesize || 0
      end

      # Value equality for immutable samples and format metadata.
      def ==(other)
        return true if equal?(other)
        return false unless other.is_a?(SampleBuffer) && @format == other.format && @sample_count == other.length

        array_samples, packed_bytes = storage_snapshot
        other_array_samples, other_packed_bytes = other.send(:storage_snapshot)
        return array_samples == other_array_samples if array_samples && other_array_samples

        if packed_bytes && other_packed_bytes
          return packed_bytes == other_packed_bytes if @format.sample_format == :pcm || packed_bytes == other_packed_bytes
        end

        sample_values_equal?(other)
      end

      alias eql? ==

      def hash
        @value_hash
      end

      # Enumerates sample values in interleaved order.
      #
      # @yield [sample]
      # @yieldparam sample [Numeric]
      # @return [Enumerator, Array<Numeric>]
      def each(&)
        return enum_for(:each) unless block_given?

        return each_packed_sample(&) if packed?

        @storage_state.samples.each(&)
      end

      # @return [Integer] number of interleaved samples
      def length
        @sample_count
      end

      alias size length

      # @return [Integer] number of audio frames
      def sample_frame_count
        @sample_count / @format.channels
      end

      # Returns a lazy sample-frame view without copying the full buffer.
      #
      # @return [FrameView]
      def frame_view
        FrameView.new(samples, @format.channels)
      end

      # Returns a lazy sample-buffer view without copying the selected frames.
      #
      # @param start_frame [Integer]
      # @param frame_length [Integer, nil]
      # @return [View]
      def view(start_frame: 0, frame_length: nil)
        View.new(samples, @format, start_frame: start_frame, frame_count: frame_length)
      end

      # Converts the buffer to another audio format/channels.
      #
      # @param new_format [Format]
      # @return [SampleBuffer]
      def convert(new_format, dither: false, dither_seed: nil, resampler: :linear)
        raise InvalidParameterError, "new_format must be Core::Format" unless new_format.is_a?(Format)
        return self if new_format == @format && !dither

        resampler = normalize_resampler!(resampler)
        dither_rng = dither_applicable?(new_format, dither) ? Random.new(dither_seed) : nil
        if @format.channels == new_format.channels && @format.sample_rate == new_format.sample_rate
          converted_samples = samples.map do |sample|
            normalized = to_normalized_float(sample, @format)
            from_normalized_float(normalized, new_format, dither_rng: dither_rng)
          end
          return self.class.new(converted_samples, new_format)
        end

        normalized_samples = samples.map { |sample| to_normalized_float(sample, @format) }
        converted_samples = convert_channels_interleaved(
          normalized_samples,
          source_channels: @format.channels,
          target_channels: new_format.channels,
          source_layout: @format.channel_layout
        )
        converted_samples = resample_interleaved(
          converted_samples,
          channels: new_format.channels,
          target_sample_rate: new_format.sample_rate,
          resampler: resampler
        )
        converted_samples.map! do |sample|
          from_normalized_float(sample, new_format, dither_rng: dither_rng)
        end

        self.class.new(converted_samples, new_format)
      rescue InvalidParameterError, InvalidFormatError
        raise
      rescue StandardError => e
        raise BufferConversionError, "failed to convert sample buffer: #{e.message}"
      end

      # Reverses sample frame order while preserving channel ordering per frame.
      #
      # @return [SampleBuffer]
      def reverse
        reversed = []
        channels = @format.channels
        source_samples = samples
        (source_samples.length - channels).step(0, -channels) do |sample_index|
          reversed.concat(source_samples.slice(sample_index, channels))
        end
        self.class.new(reversed, @format)
      end

      # Slices the buffer by frame index and frame count.
      #
      # @param start_frame [Integer]
      # @param frame_length [Integer]
      # @return [SampleBuffer]
      def slice(start_frame, frame_length)
        unless start_frame.is_a?(Integer) && start_frame >= 0
          raise InvalidParameterError, "start_frame must be a non-negative Integer: #{start_frame.inspect}"
        end
        unless frame_length.is_a?(Integer) && frame_length >= 0
          raise InvalidParameterError, "frame_length must be a non-negative Integer: #{frame_length.inspect}"
        end

        view(start_frame: start_frame, frame_length: frame_length).to_sample_buffer
      end

      def concat(other)
        raise InvalidParameterError, "other must be Core::SampleBuffer" unless other.is_a?(SampleBuffer)

        rhs = other.format == @format ? other : other.convert(@format)
        self.class.new(samples + rhs.samples, @format)
      end

      alias + concat

      private

      def normalize_storage!(storage)
        value = storage.to_sym
        return value if STORAGE_TYPES.include?(value)

        raise InvalidParameterError, "storage must be :array or :packed"
      rescue NoMethodError
        raise InvalidParameterError, "storage must be Symbol/String"
      end

      def pack_samples(samples, format)
        return samples.pack(format.bit_depth == 32 ? "e*" : "E*") if format.sample_format == :float

        case format.bit_depth
        when 8 then samples.pack("c*")
        when 16 then samples.pack("s<*")
        when 24 then pack_pcm24(samples)
        when 32 then samples.pack("l<*")
        end
      end

      def unpack_samples(bytes, format)
        return bytes.unpack(format.bit_depth == 32 ? "e*" : "E*") if format.sample_format == :float

        case format.bit_depth
        when 8 then bytes.unpack("c*")
        when 16 then bytes.unpack("s<*")
        when 24 then unpack_pcm24(bytes)
        when 32 then bytes.unpack("l<*")
        end
      end

      def pack_pcm24(samples)
        packed = String.new(capacity: samples.length * 3, encoding: Encoding::BINARY)
        samples.each do |sample|
          value = sample.negative? ? sample + 0x1000000 : sample
          packed << (value & 0xFF) << ((value >> 8) & 0xFF) << ((value >> 16) & 0xFF)
        end
        packed
      end

      def unpack_pcm24(bytes)
        samples = Array.new(bytes.bytesize / 3)
        samples.length.times do |index|
          offset = index * 3
          low = bytes.getbyte(offset)
          middle = bytes.getbyte(offset + 1)
          high = bytes.getbyte(offset + 2)
          value = low | (middle << 8) | (high << 16)
          samples[index] = value.anybits?(0x800000) ? value - 0x1000000 : value
        end
        samples
      end

      def each_packed_sample
        array_samples, packed_samples = storage_snapshot
        return array_samples.each { |sample| yield sample } unless packed_samples

        if @format.sample_format == :pcm && @format.bit_depth == 24
          chunk_bytes = PACKED_ENUMERATION_CHUNK_SAMPLES * 3
          0.step(packed_samples.bytesize - 1, chunk_bytes) do |offset|
            unpack_pcm24(packed_samples.byteslice(offset, chunk_bytes)).each { |sample| yield sample }
          end
          return self
        end

        directive, byte_width = packed_directive_and_width(@format)
        chunk_bytes = PACKED_ENUMERATION_CHUNK_SAMPLES * byte_width
        0.step(packed_samples.bytesize - 1, chunk_bytes) do |offset|
          packed_samples.byteslice(offset, chunk_bytes).unpack("#{directive}*").each { |sample| yield sample }
        end
        self
      end

      def storage_snapshot
        state = @storage_mutex.synchronize { @storage_state }
        [state.samples, state.packed_samples]
      end

      def storage_state(samples:, packed_samples:, type:)
        StorageState.new(samples: samples, packed_samples: packed_samples, type: type).freeze
      end

      def sample_values_equal?(other)
        left = each
        right = other.each
        @sample_count.times.all? { left.next == right.next }
      end

      def sample_value_hash(values, canonical_float: false)
        probe_count = [values.length, HASH_PROBE_COUNT].min
        return [@format, values.length].hash if probe_count.zero?

        indexes = if probe_count == 1
                    [0]
                  else
                    Array.new(probe_count) { |index| (index * (values.length - 1)) / (probe_count - 1) }
                  end
        probes = indexes.map { |index| values.fetch(index) }
        probes.map! { |value| canonical_float_value(value) } if canonical_float
        [@format, values.length, *probes].hash
      end

      def canonical_float_value(value)
        directive = @format.bit_depth == 32 ? "e" : "E"
        [value].pack(directive).unpack1(directive)
      end

      def packed_directive_and_width(format)
        return format.bit_depth == 32 ? ["e", 4] : ["E", 8] if format.sample_format == :float

        { 8 => ["c", 1], 16 => ["s<", 2], 32 => ["l<", 4] }.fetch(format.bit_depth)
      end

      def validate_samples!(samples)
        invalid_index = samples.index do |sample|
          !sample.is_a?(Numeric) || !sample.real? || !sample.respond_to?(:finite?) || !sample.finite?
        end
        return unless invalid_index

        raise InvalidParameterError, "sample at index #{invalid_index} must be a finite real Numeric"
      end

      def validate_interleaving!(sample_count, channels)
        return if (sample_count % channels).zero?

        raise InvalidParameterError,
              "sample count (#{sample_count}) must be divisible by channels (#{channels})"
      end

      def coerce_samples(samples, format)
        samples.map do |sample|
          if format.sample_format == :float
            sample.to_f.clamp(-1.0, 1.0)
          else
            coerce_pcm_sample(sample, format)
          end
        end
      end

      def coerce_pcm_sample(sample, format)
        if sample.is_a?(Float) && sample.between?(-1.0, 1.0)
          float_to_pcm(sample, format)
        else
          shift = format.bit_depth - format.valid_bits
          min = -(2**(format.valid_bits - 1)) << shift
          max = ((2**(format.valid_bits - 1)) - 1) << shift
          (sample.to_i.clamp(min, max) >> shift) << shift
        end
      end

      def to_normalized_float(sample, format)
        return sample.to_f.clamp(-1.0, 1.0) if format.sample_format == :float

        shift = format.bit_depth - format.valid_bits
        positive_scale = (((2**(format.valid_bits - 1)) - 1) << shift).to_f
        negative_scale = ((2**(format.valid_bits - 1)) << shift).to_f
        scale = sample.negative? ? negative_scale : positive_scale
        (sample.to_f / scale).clamp(-1.0, 1.0)
      end

      def from_normalized_float(sample, format, dither_rng: nil)
        value = sample.to_f.clamp(-1.0, 1.0)
        return value if format.sample_format == :float

        value = apply_tpdf_dither(value, format, dither_rng) if dither_rng
        float_to_pcm(value, format)
      end

      def apply_tpdf_dither(value, format, rng)
        max = ((2**(format.valid_bits - 1)) - 1).to_f
        (value + ((rng.rand - rng.rand) / max)).clamp(-1.0, 1.0)
      end

      def dither_applicable?(new_format, requested)
        return false unless requested && new_format.sample_format == :pcm
        return true if @format.sample_format == :float

        @format.valid_bits > new_format.valid_bits
      end

      def float_to_pcm(sample, format)
        max = (2**(format.valid_bits - 1)) - 1
        min = -(2**(format.valid_bits - 1))
        scale = sample.negative? ? -min : max
        ((sample * scale).round.clamp(min, max)) << (format.bit_depth - format.valid_bits)
      end

      def convert_channels_interleaved(samples, source_channels:, target_channels:, source_layout: nil)
        return samples if samples.empty? || source_channels == target_channels

        output = []
        samples.each_slice(source_channels) do |frame|
          converted = if target_channels == 1
                        [frame.sum / frame.length.to_f]
                      elsif source_channels == 1
                        Array.new(target_channels, frame.first)
                      elsif source_channels > 2 && target_channels == 2
                        downmix_to_stereo(frame, source_layout)
                      elsif source_channels > target_channels
                        truncate_and_fold(frame, target_channels)
                      else
                        upmix_with_duplication(frame, target_channels)
                      end
          output.concat(converted)
        end
        output
      end

      def normalize_resampler!(resampler)
        value = resampler.to_sym
        return value if %i[linear windowed_sinc].include?(value)

        raise InvalidParameterError, "resampler must be :linear or :windowed_sinc"
      rescue NoMethodError
        raise InvalidParameterError, "resampler must be Symbol/String"
      end

      def resample_interleaved(samples, channels:, target_sample_rate:, resampler:)
        return samples if samples.empty? || @format.sample_rate == target_sample_rate

        source_frame_count = samples.length / channels
        target_frame_count = resampled_frame_count(source_frame_count, target_sample_rate)
        return [] if target_frame_count.zero?

        output = Array.new(target_frame_count * channels)
        target_frame_count.times do |target_index|
          source_position = (target_index * @format.sample_rate.to_f) / target_sample_rate
          if resampler == :windowed_sinc
            channels.times do |channel|
              output[(target_index * channels) + channel] = windowed_sinc_sample(
                samples,
                source_position,
                channel,
                channels,
                source_frame_count,
                target_sample_rate
              )
            end
            next
          end

          lower_index = source_position.floor
          upper_index = [lower_index + 1, source_frame_count - 1].min
          fraction = source_position - lower_index

          channels.times do |channel|
            lower = samples.fetch((lower_index * channels) + channel)
            upper = samples.fetch((upper_index * channels) + channel)
            output[(target_index * channels) + channel] = lower + ((upper - lower) * fraction)
          end
        end
        output
      end

      def windowed_sinc_sample(samples, source_position, channel, channels, source_frame_count, target_sample_rate)
        cutoff = [1.0, target_sample_rate.to_f / @format.sample_rate].min
        radius = (8 / cutoff).ceil.clamp(8, 64)
        center = source_position.floor
        start_index = [center - radius + 1, 0].max
        end_index = [center + radius, source_frame_count - 1].min
        weighted_sum = 0.0
        weight_sum = 0.0
        (start_index..end_index).each do |source_index|
          distance = source_position - source_index
          weight = cutoff * sinc(distance * cutoff) * hann_window(distance, radius)
          weighted_sum += samples.fetch((source_index * channels) + channel) * weight
          weight_sum += weight
        end
        return weighted_sum / weight_sum unless weight_sum.zero?

        samples.fetch((center.clamp(0, source_frame_count - 1) * channels) + channel)
      end

      def sinc(value)
        return 1.0 if value.abs < 1e-12

        x = Math::PI * value
        Math.sin(x) / x
      end

      def hann_window(distance, radius)
        normalized = distance.abs / radius.to_f
        return 0.0 if normalized > 1.0

        0.5 + (0.5 * Math.cos(Math::PI * normalized))
      end

      def resampled_frame_count(source_frame_count, target_sample_rate)
        ((source_frame_count * target_sample_rate.to_f) / @format.sample_rate).round
      end

      def downmix_to_stereo(frame, source_layout)
        positions = source_layout || default_channel_layout(frame.length)
        by_position = positions.zip(frame).to_h
        left = by_position.fetch(:front_left, frame[0] || 0.0)
        right = by_position.fetch(:front_right, frame[1] || left)
        center = by_position.fetch(:front_center, 0.0)
        lfe = by_position.fetch(:low_frequency, 0.0)
        left_surround = by_position.fetch(:side_left, by_position.fetch(:back_left, 0.0))
        right_surround = by_position.fetch(:side_right, by_position.fetch(:back_right, 0.0))
        known = %i[front_left front_right front_center low_frequency side_left side_right back_left back_right]
        extras = by_position.reject { |position, _| known.include?(position) }.values.sum

        left_mix = left + (center * 0.707) + (lfe * 0.5) + (left_surround * 0.707) + (extras * 0.5)
        right_mix = right + (center * 0.707) + (lfe * 0.5) + (right_surround * 0.707) + (extras * 0.5)
        [left_mix, right_mix]
      end

      def truncate_and_fold(frame, target_channels)
        reduced = frame.first(target_channels).dup
        extras = frame.drop(target_channels)
        return reduced if extras.empty?

        extra_mix = extras.sum / target_channels.to_f
        reduced.map { |sample| sample + extra_mix }
      end

      def default_channel_layout(channels)
        {
          1 => %i[front_center],
          2 => %i[front_left front_right],
          3 => %i[front_left front_right front_center],
          4 => %i[front_left front_right back_left back_right],
          5 => %i[front_left front_right front_center back_left back_right],
          6 => %i[front_left front_right front_center low_frequency side_left side_right],
          7 => %i[front_left front_right front_center low_frequency back_center side_left side_right],
          8 => %i[front_left front_right front_center low_frequency back_left back_right side_left side_right]
        }.fetch(channels) { Array.new(channels) { |index| :"channel_#{index}" } }
      end

      def upmix_with_duplication(frame, target_channels)
        result = frame.dup
        result << frame[result.length % frame.length] while result.length < target_channels
        result
      end

    end
  end
end
