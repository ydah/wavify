# frozen_string_literal: true

module Wavify
  module Core
    # Immutable interleaved sample container with format metadata.
    #
    # Samples are stored in interleaved order (`L, R, L, R, ...`) for
    # multi-channel audio.
    class SampleBuffer
      include Enumerable

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

      # Converts the buffer to another audio format/channels.
      #
      # @param new_format [Format]
      # @return [SampleBuffer]
      def convert(new_format)
        raise InvalidParameterError, "new_format must be Core::Format" unless new_format.is_a?(Format)

        frames = frame_view.map do |frame|
          frame.map { |sample| to_normalized_float(sample, @format) }
        end

        converted_frames = convert_channels(frames, new_format.channels)
        converted_samples = converted_frames.flatten.map do |sample|
          from_normalized_float(sample, new_format)
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
        reversed = frame_view.reverse.flatten
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

        sliced = frame_view.slice(start_frame, frame_length) || []
        self.class.new(sliced.flatten, @format)
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

      def frame_view
        @samples.each_slice(@format.channels).map(&:dup)
      end

      def to_normalized_float(sample, format)
        return sample.to_f.clamp(-1.0, 1.0) if format.sample_format == :float

        max = ((2**(format.bit_depth - 1)) - 1).to_f
        (sample.to_f / max).clamp(-1.0, 1.0)
      end

      def from_normalized_float(sample, format)
        value = sample.to_f.clamp(-1.0, 1.0)
        return value if format.sample_format == :float

        float_to_pcm(value, format.bit_depth)
      end

      def float_to_pcm(sample, bit_depth)
        max = (2**(bit_depth - 1)) - 1
        min = -(2**(bit_depth - 1))
        (sample * max).round.clamp(min, max)
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
