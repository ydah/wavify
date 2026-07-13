# frozen_string_literal: true

module Wavify
  module Core
    # Immutable interleaved sample container with format metadata.
    #
    # Samples are stored in interleaved order (`L, R, L, R, ...`) for
    # multi-channel audio.
    class SampleBuffer
      include Enumerable

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
          each.to_a.freeze
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

      attr_reader :samples, :format, :duration

      # @param samples [Array<Numeric>] interleaved sample values
      # @param format [Format] sample encoding and channel layout
      def initialize(samples, format)
        raise InvalidParameterError, "format must be Core::Format" unless format.is_a?(Format)
        raise InvalidParameterError, "samples must be an Array" unless samples.is_a?(Array)

        validate_samples!(samples)
        validate_interleaving!(samples.length, format.channels)

        @format = format
        @samples = coerce_samples(samples, format).freeze
        @duration = Duration.from_samples(sample_frame_count, format.sample_rate)
      end

      # Value equality for immutable samples and format metadata.
      def ==(other)
        other.is_a?(SampleBuffer) && @format == other.format && @samples == other.samples
      end

      alias eql? ==

      def hash
        [@format, @samples].hash
      end

      # Enumerates sample values in interleaved order.
      #
      # @yield [sample]
      # @yieldparam sample [Numeric]
      # @return [Enumerator, Array<Numeric>]
      def each(&)
        return enum_for(:each) unless block_given?

        @samples.each(&)
      end

      # @return [Integer] number of interleaved samples
      def length
        @samples.length
      end

      alias size length

      # @return [Integer] number of audio frames
      def sample_frame_count
        @samples.length / @format.channels
      end

      # Returns a lazy sample-frame view without copying the full buffer.
      #
      # @return [FrameView]
      def frame_view
        FrameView.new(@samples, @format.channels)
      end

      # Returns a lazy sample-buffer view without copying the selected frames.
      #
      # @param start_frame [Integer]
      # @param frame_length [Integer, nil]
      # @return [View]
      def view(start_frame: 0, frame_length: nil)
        View.new(@samples, @format, start_frame: start_frame, frame_count: frame_length)
      end

      # Converts the buffer to another audio format/channels.
      #
      # @param new_format [Format]
      # @return [SampleBuffer]
      def convert(new_format, dither: false, dither_seed: nil, resampler: :linear)
        raise InvalidParameterError, "new_format must be Core::Format" unless new_format.is_a?(Format)

        resampler = normalize_resampler!(resampler)
        dither_rng = dither_applicable?(new_format, dither) ? Random.new(dither_seed) : nil
        frames = frame_view.map do |frame|
          frame.map { |sample| to_normalized_float(sample, @format) }
        end

        converted_frames = convert_channels(frames, new_format.channels)
        converted_frames = resample_frames(converted_frames, new_format.sample_rate, resampler: resampler)
        converted_samples = converted_frames.flatten.map do |sample|
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
        (@samples.length - channels).step(0, -channels) do |sample_index|
          reversed.concat(@samples.slice(sample_index, channels))
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
        self.class.new(@samples + rhs.samples, @format)
      end

      alias + concat

      private

      def validate_samples!(samples)
        invalid_index = samples.index { |sample| !sample.is_a?(Numeric) }
        return unless invalid_index

        raise InvalidParameterError, "sample at index #{invalid_index} must be Numeric"
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
            coerce_pcm_sample(sample, format.bit_depth)
          end
        end
      end

      def coerce_pcm_sample(sample, bit_depth)
        if sample.is_a?(Float) && sample.between?(-1.0, 1.0)
          float_to_pcm(sample, bit_depth)
        else
          min = -(2**(bit_depth - 1))
          max = (2**(bit_depth - 1)) - 1
          sample.to_i.clamp(min, max)
        end
      end

      def to_normalized_float(sample, format)
        return sample.to_f.clamp(-1.0, 1.0) if format.sample_format == :float

        positive_scale = ((2**(format.bit_depth - 1)) - 1).to_f
        negative_scale = (2**(format.bit_depth - 1)).to_f
        scale = sample.negative? ? negative_scale : positive_scale
        (sample.to_f / scale).clamp(-1.0, 1.0)
      end

      def from_normalized_float(sample, format, dither_rng: nil)
        value = sample.to_f.clamp(-1.0, 1.0)
        return value if format.sample_format == :float

        value = apply_tpdf_dither(value, format, dither_rng) if dither_rng
        float_to_pcm(value, format.bit_depth)
      end

      def apply_tpdf_dither(value, format, rng)
        max = ((2**(format.bit_depth - 1)) - 1).to_f
        (value + ((rng.rand - rng.rand) / max)).clamp(-1.0, 1.0)
      end

      def dither_applicable?(new_format, requested)
        return false unless requested && new_format.sample_format == :pcm
        return true if @format.sample_format == :float

        @format.bit_depth > new_format.bit_depth
      end

      def float_to_pcm(sample, bit_depth)
        max = (2**(bit_depth - 1)) - 1
        min = -(2**(bit_depth - 1))
        scale = sample.negative? ? -min : max
        (sample * scale).round.clamp(min, max)
      end

      def convert_channels(frames, target_channels)
        return frames if frames.empty?

        source_channels = frames.first.length
        return frames if source_channels == target_channels

        return frames.map { |frame| [frame.sum / frame.length.to_f] } if target_channels == 1

        return frames.map { |frame| Array.new(target_channels, frame.first) } if source_channels == 1

        return frames.map { |frame| downmix_to_stereo(frame) } if source_channels > 2 && target_channels == 2

        return frames.map { |frame| truncate_and_fold(frame, target_channels) } if source_channels > target_channels

        frames.map { |frame| upmix_with_duplication(frame, target_channels) }
      end

      def normalize_resampler!(resampler)
        value = resampler.to_sym
        return value if %i[linear windowed_sinc].include?(value)

        raise InvalidParameterError, "resampler must be :linear or :windowed_sinc"
      rescue NoMethodError
        raise InvalidParameterError, "resampler must be Symbol/String"
      end

      def resample_frames(frames, target_sample_rate, resampler:)
        return frames if frames.empty? || @format.sample_rate == target_sample_rate

        source_frame_count = frames.length
        target_frame_count = resampled_frame_count(source_frame_count, target_sample_rate)
        return [] if target_frame_count.zero?

        channels = frames.first.length
        Array.new(target_frame_count) do |target_index|
          source_position = (target_index * @format.sample_rate.to_f) / target_sample_rate
          next windowed_sinc_frame(frames, source_position, channels) if resampler == :windowed_sinc

          lower_index = source_position.floor
          upper_index = [lower_index + 1, source_frame_count - 1].min
          fraction = source_position - lower_index

          lower_frame = frames.fetch(lower_index)
          upper_frame = frames.fetch(upper_index)
          Array.new(channels) do |channel|
            lower_frame.fetch(channel) + ((upper_frame.fetch(channel) - lower_frame.fetch(channel)) * fraction)
          end
        end
      end

      def windowed_sinc_frame(frames, source_position, channels)
        radius = 8
        center = source_position.floor
        start_index = [center - radius + 1, 0].max
        end_index = [center + radius, frames.length - 1].min

        Array.new(channels) do |channel|
          weighted_sum = 0.0
          weight_sum = 0.0
          (start_index..end_index).each do |source_index|
            distance = source_position - source_index
            weight = sinc(distance) * hann_window(distance, radius)
            weighted_sum += frames.fetch(source_index).fetch(channel) * weight
            weight_sum += weight
          end
          weight_sum.zero? ? frames.fetch(center.clamp(0, frames.length - 1)).fetch(channel) : (weighted_sum / weight_sum)
        end
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

      def downmix_to_stereo(frame)
        left = frame[0] || 0.0
        right = frame[1] || left
        center = frame[2] || 0.0
        lfe = frame[3] || 0.0
        left_surround = frame[4] || 0.0
        right_surround = frame[5] || 0.0
        extras = (frame[6..] || []).sum

        left_mix = left + (center * 0.707) + (lfe * 0.5) + (left_surround * 0.707) + (extras * 0.5)
        right_mix = right + (center * 0.707) + (lfe * 0.5) + (right_surround * 0.707) + (extras * 0.5)
        [left_mix.clamp(-1.0, 1.0), right_mix.clamp(-1.0, 1.0)]
      end

      def truncate_and_fold(frame, target_channels)
        reduced = frame.first(target_channels).dup
        extras = frame.drop(target_channels)
        return reduced if extras.empty?

        extra_mix = extras.sum / target_channels.to_f
        reduced.map { |sample| (sample + extra_mix).clamp(-1.0, 1.0) }
      end

      def upmix_with_duplication(frame, target_channels)
        result = frame.dup
        result << frame[result.length % frame.length] while result.length < target_channels
        result
      end

    end
  end
end
