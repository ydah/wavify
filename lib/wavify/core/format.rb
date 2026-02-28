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

      attr_reader :channels, :sample_rate, :bit_depth, :sample_format

      # @param channels [Integer] number of interleaved channels (1..32)
      # @param sample_rate [Integer] sampling rate in Hz
      # @param bit_depth [Integer] bits per sample
      # @param sample_format [Symbol,String] `:pcm` or `:float`
      def initialize(channels:, sample_rate:, bit_depth:, sample_format: :pcm)
        @channels = validate_channels(channels)
        @sample_rate = validate_sample_rate(sample_rate)
        @sample_format = validate_sample_format(sample_format)
        @bit_depth = validate_bit_depth(bit_depth, @sample_format)
        freeze
      end

      # Returns a new format with one or more fields replaced.
      #
      # @return [Format]
      def with(channels: nil, sample_rate: nil, bit_depth: nil, sample_format: nil)
        self.class.new(
          channels: channels || @channels,
          sample_rate: sample_rate || @sample_rate,
          bit_depth: bit_depth || @bit_depth,
          sample_format: sample_format || @sample_format
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
          @sample_format == other.sample_format
      end

      alias eql? ==

      # @return [Integer] hash value compatible with {#eql?}
      def hash
        [@channels, @sample_rate, @bit_depth, @sample_format].hash
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

      public

      # Stereo 44.1kHz 16-bit PCM preset.
      CD_QUALITY = new(channels: 2, sample_rate: 44_100, bit_depth: 16, sample_format: :pcm)
      # Stereo 96kHz 24-bit PCM preset.
      DVD_QUALITY = new(channels: 2, sample_rate: 96_000, bit_depth: 24, sample_format: :pcm)
      # Mono 16kHz 16-bit PCM preset for speech-focused workflows.
      VOICE = new(channels: 1, sample_rate: 16_000, bit_depth: 16, sample_format: :pcm)
    end
  end
end
