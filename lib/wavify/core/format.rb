# frozen_string_literal: true

module Wavify
  # Core immutable value objects used by codecs, DSP, and high-level APIs.
  module Core
    # Describes the audio sample layout (channels, sample rate, and sample type).
    class Format
      # Supported symbolic sample format kinds.
      SUPPORTED_SAMPLE_FORMATS = %i[pcm float].freeze
      # Allowed bit depths for integer PCM.
      PCM_BIT_DEPTHS = [8, 16, 24, 32].freeze
      # Allowed bit depths for floating point samples.
      FLOAT_BIT_DEPTHS = [32, 64].freeze
      # Speaker positions understood by channel-layout-aware conversions.
      CHANNEL_POSITIONS = %i[
        front_left front_right front_center low_frequency back_left back_right
        front_left_of_center front_right_of_center back_center side_left side_right
        top_center top_front_left top_front_center top_front_right top_back_left
        top_back_center top_back_right
      ].freeze
      # Conventional speaker order used when no explicit channel layout exists.
      DEFAULT_CHANNEL_LAYOUTS = {
        1 => %i[front_center],
        2 => %i[front_left front_right],
        3 => %i[front_left front_right front_center],
        4 => %i[front_left front_right back_left back_right],
        5 => %i[front_left front_right front_center back_left back_right],
        6 => %i[front_left front_right front_center low_frequency side_left side_right],
        7 => %i[front_left front_right front_center low_frequency back_center side_left side_right],
        8 => %i[front_left front_right front_center low_frequency back_left back_right side_left side_right]
      }.transform_values(&:freeze).freeze
      UNSPECIFIED_LAYOUT = Object.new.freeze # :nodoc:

      attr_reader :channels, :sample_rate, :bit_depth, :valid_bits, :sample_format, :channel_layout

      # @param channels [Integer] number of interleaved channels (1..32)
      # @param sample_rate [Integer] sampling rate in Hz
      # @param bit_depth [Integer] bits per sample
      # @param valid_bits [Integer, nil] significant bits within the sample container
      # @param sample_format [Symbol,String] `:pcm` or `:float`
      # @param channel_layout [Array<Symbol>, nil] ordered speaker positions
      def initialize(channels:, sample_rate:, bit_depth:, sample_format: :pcm, valid_bits: nil,
                     channel_layout: UNSPECIFIED_LAYOUT)
        @channels = validate_channels(channels)
        @sample_rate = validate_sample_rate(sample_rate)
        @sample_format = validate_sample_format(sample_format)
        @bit_depth = validate_bit_depth(bit_depth, @sample_format)
        @valid_bits = validate_valid_bits(valid_bits || @bit_depth)
        requested_layout = if channel_layout.equal?(UNSPECIFIED_LAYOUT) || channel_layout.nil?
                             DEFAULT_CHANNEL_LAYOUTS[@channels]
                           else
                             channel_layout
                           end
        @channel_layout = validate_channel_layout(requested_layout)
        freeze
      end

      # Returns a new format with one or more fields replaced.
      #
      # @return [Format]
      def with(channels: nil, sample_rate: nil, bit_depth: nil, sample_format: nil, valid_bits: nil,
               channel_layout: UNSPECIFIED_LAYOUT)
        target_channels = channels || @channels
        target_bit_depth = bit_depth || @bit_depth
        target_sample_format = sample_format || @sample_format
        self.class.new(
          channels: target_channels,
          sample_rate: sample_rate || @sample_rate,
          bit_depth: target_bit_depth,
          sample_format: target_sample_format,
          valid_bits: valid_bits || preserved_valid_bits(target_bit_depth, target_sample_format),
          channel_layout: resolved_channel_layout(channel_layout, target_channels)
        )
      end

      def mono?
        @channels == 1
      end

      def stereo?
        @channels == 2
      end

      # @return [Integer] bytes per audio frame (all channels)
      def block_align
        @channels * bytes_per_sample
      end

      # @return [Integer] bytes per second for this format
      def byte_rate
        @sample_rate * block_align
      end

      # @return [Integer] bytes used by one sample value
      def bytes_per_sample
        @bit_depth / 8
      end

      # Value equality for audio format parameters.
      #
      # @param other [Object]
      # @return [Boolean]
      def ==(other)
        return false unless other.is_a?(Format)

          @channels == other.channels &&
          @sample_rate == other.sample_rate &&
          @bit_depth == other.bit_depth &&
          @valid_bits == other.valid_bits &&
          @sample_format == other.sample_format &&
          @channel_layout == other.channel_layout
      end

      alias eql? ==

      # @return [Integer] hash value compatible with {#eql?}
      def hash
        [@channels, @sample_rate, @bit_depth, @valid_bits, @sample_format, @channel_layout].hash
      end

      private

      def validate_channels(channels)
        unless channels.is_a?(Integer) && channels.between?(1, 32)
          raise InvalidFormatError, "channels must be an Integer between 1 and 32: #{channels.inspect}"
        end

        channels
      end

      def validate_sample_rate(sample_rate)
        unless sample_rate.is_a?(Integer) && sample_rate.between?(8_000, 768_000)
          raise InvalidFormatError, "sample_rate must be an Integer between 8000 and 768000: #{sample_rate.inspect}"
        end

        sample_rate
      end

      def validate_sample_format(sample_format)
        format = sample_format.to_sym
        raise UnsupportedFormatError, "unsupported sample_format: #{sample_format.inspect}" unless SUPPORTED_SAMPLE_FORMATS.include?(format)

        format
      rescue NoMethodError
        raise InvalidFormatError, "sample_format must be Symbol/String: #{sample_format.inspect}"
      end

      def validate_bit_depth(bit_depth, sample_format)
        raise InvalidFormatError, "bit_depth must be an Integer: #{bit_depth.inspect}" unless bit_depth.is_a?(Integer)

        allowed_depths = sample_format == :pcm ? PCM_BIT_DEPTHS : FLOAT_BIT_DEPTHS
        unless allowed_depths.include?(bit_depth)
          raise InvalidFormatError,
                "bit_depth #{bit_depth} is invalid for #{sample_format}. Allowed: #{allowed_depths.join(', ')}"
        end

        bit_depth
      end

      def validate_valid_bits(valid_bits)
        unless valid_bits.is_a?(Integer) && valid_bits.positive? && valid_bits <= @bit_depth
          raise InvalidFormatError, "valid_bits must be an Integer between 1 and #{@bit_depth}: #{valid_bits.inspect}"
        end
        if @sample_format == :float && valid_bits != @bit_depth
          raise InvalidFormatError, "floating-point valid_bits must equal bit_depth"
        end

        valid_bits
      end

      def validate_channel_layout(channel_layout)
        return nil if channel_layout.nil?
        raise InvalidFormatError, "channel_layout must be an Array" unless channel_layout.is_a?(Array)
        unless channel_layout.length == @channels
          raise InvalidFormatError, "channel_layout must contain exactly #{@channels} positions"
        end

        normalized = channel_layout.map do |position|
          value = position.to_sym
          unless CHANNEL_POSITIONS.include?(value)
            raise InvalidFormatError, "unsupported channel position: #{position.inspect}"
          end

          value
        rescue NoMethodError
          raise InvalidFormatError, "channel positions must be Symbol/String: #{position.inspect}"
        end
        raise InvalidFormatError, "channel_layout positions must be unique" unless normalized.uniq.length == normalized.length

        normalized.freeze
      end

      def preserved_valid_bits(target_bit_depth, target_sample_format)
        return @valid_bits if target_bit_depth == @bit_depth && target_sample_format.to_sym == @sample_format

        nil
      end

      def resolved_channel_layout(channel_layout, target_channels)
        return channel_layout unless channel_layout.equal?(UNSPECIFIED_LAYOUT)
        return @channel_layout if target_channels == @channels

        DEFAULT_CHANNEL_LAYOUTS[target_channels]
      end

      # Stereo 44.1kHz 16-bit PCM preset.
      CD_QUALITY = new(channels: 2, sample_rate: 44_100, bit_depth: 16, sample_format: :pcm)
      # Stereo 96kHz 24-bit PCM preset.
      DVD_QUALITY = new(channels: 2, sample_rate: 96_000, bit_depth: 24, sample_format: :pcm)
      # Mono 16kHz 16-bit PCM preset for speech-focused workflows.
      VOICE = new(channels: 1, sample_rate: 16_000, bit_depth: 16, sample_format: :pcm)

    end
  end
end
