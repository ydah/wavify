# frozen_string_literal: true

module Wavify
  module Codecs
    # Raw PCM/float sample codec.
    #
    # Since raw audio has no container metadata, callers must provide a
    # {Wavify::Core::Format} when reading/stream-reading/metadata.
    class Raw < Base
      # Recognized filename extensions.
      EXTENSIONS = %w[.raw .pcm].freeze

      class << self
        # @param io_or_path [String, IO]
        # @return [Boolean]
        def can_read?(io_or_path)
          return true if io_or_path.respond_to?(:read)
          return false unless io_or_path.is_a?(String)

          EXTENSIONS.include?(File.extname(io_or_path).downcase)
        end

        # Reads a raw audio file/IO into a sample buffer.
        #
        # @param io_or_path [String, IO]
        # @param format [Wavify::Core::Format]
        # @return [Wavify::Core::SampleBuffer]
        def read(io_or_path, format: nil)
          target_format = validate_format!(format)
          io, close_io = open_input(io_or_path)
          data = io.read || "".b
          samples = decode_samples(data, target_format)
          Core::SampleBuffer.new(samples, target_format)
        ensure
          io.close if close_io && io
        end

        # Writes a raw audio buffer to a path/IO.
        #
        # @param io_or_path [String, IO]
        # @param sample_buffer [Wavify::Core::SampleBuffer]
        # @param format [Wavify::Core::Format]
        # @return [String, IO]
        def write(io_or_path, sample_buffer, format:)
          raise InvalidParameterError, "sample_buffer must be Core::SampleBuffer" unless sample_buffer.is_a?(Core::SampleBuffer)

          target_format = validate_format!(format)
          buffer = sample_buffer.format == target_format ? sample_buffer : sample_buffer.convert(target_format)

          io, close_io = open_output(io_or_path)
          io.write(encode_samples(buffer.samples, target_format))
          io.flush if io.respond_to?(:flush)
          io.rewind if io.respond_to?(:rewind)
          io_or_path
        ensure
          io.close if close_io && io
        end

        # Streams raw audio decoding in frame chunks.
        #
        # @param io_or_path [String, IO]
        # @param format [Wavify::Core::Format]
        # @param chunk_size [Integer]
        # @return [Enumerator]
        def stream_read(io_or_path, format:, chunk_size: 4096)
          return enum_for(__method__, io_or_path, format: format, chunk_size: chunk_size) unless block_given?

          target_format = validate_format!(format)
          io, close_io = open_input(io_or_path)
          bytes_per_frame = target_format.block_align
          raw_chunk_size = chunk_size * bytes_per_frame

          loop do
            chunk = io.read(raw_chunk_size)
            break if chunk.nil? || chunk.empty?

            raise InvalidFormatError, "raw data chunk does not align with format frame size" unless (chunk.bytesize % bytes_per_frame).zero?

            samples = decode_samples(chunk, target_format)
            yield Core::SampleBuffer.new(samples, target_format)
          end
        ensure
          io.close if close_io && io
        end

        # Streams raw audio encoding via a yielded chunk writer.
        #
        # @param io_or_path [String, IO]
        # @param format [Wavify::Core::Format]
        # @return [Enumerator, String, IO]
        def stream_write(io_or_path, format:)
          return enum_for(__method__, io_or_path, format: format) unless block_given?

          target_format = validate_format!(format)
          io, close_io = open_output(io_or_path)

          writer = lambda do |sample_buffer|
            raise InvalidParameterError, "stream chunk must be Core::SampleBuffer" unless sample_buffer.is_a?(Core::SampleBuffer)

            buffer = sample_buffer.format == target_format ? sample_buffer : sample_buffer.convert(target_format)
            io.write(encode_samples(buffer.samples, target_format))
          end

          yield writer
          io.flush if io.respond_to?(:flush)
          io.rewind if io.respond_to?(:rewind)
          io_or_path
        ensure
          io.close if close_io && io
        end

        # Reads raw audio metadata using byte size and explicit format.
        #
        # @param io_or_path [String, IO]
        # @param format [Wavify::Core::Format]
        # @return [Hash]
        def metadata(io_or_path, format:)
          target_format = validate_format!(format)
          io, close_io = open_input(io_or_path)
          byte_size = io.respond_to?(:size) ? io.size : io.read&.bytesize.to_i
          sample_frames = byte_size / target_format.block_align

          {
            format: target_format,
            sample_frame_count: sample_frames,
            duration: Core::Duration.from_samples(sample_frames, target_format.sample_rate)
          }
        ensure
          io.close if close_io && io
        end

        private

        def validate_format!(format)
          raise InvalidFormatError, "format is required for raw pcm codec" unless format.is_a?(Core::Format)

          format
        end

        def decode_samples(data, format)
          if format.sample_format == :float
            return data.unpack("e*") if format.bit_depth == 32
            return data.unpack("E*") if format.bit_depth == 64
          elsif format.sample_format == :pcm
            return data.unpack("C*").map { |byte| byte - 128 } if format.bit_depth == 8
            return data.unpack("s<*") if format.bit_depth == 16
            return decode_pcm24(data) if format.bit_depth == 24
            return data.unpack("l<*") if format.bit_depth == 32
          end

          raise UnsupportedFormatError, "unsupported raw format: #{format.sample_format}/#{format.bit_depth}"
        end

        def encode_samples(samples, format)
          if format.sample_format == :float
            normalized = samples.map { |sample| sample.to_f.clamp(-1.0, 1.0) }
            return normalized.pack("e*") if format.bit_depth == 32
            return normalized.pack("E*") if format.bit_depth == 64
          elsif format.sample_format == :pcm
            min = -(2**(format.bit_depth - 1))
            max = (2**(format.bit_depth - 1)) - 1
            ints = samples.map { |sample| sample.to_i.clamp(min, max) }
            return ints.map { |sample| sample + 128 }.pack("C*") if format.bit_depth == 8
            return ints.pack("s<*") if format.bit_depth == 16
            return encode_pcm24(ints) if format.bit_depth == 24
            return ints.pack("l<*") if format.bit_depth == 32
          end

          raise UnsupportedFormatError, "unsupported raw format: #{format.sample_format}/#{format.bit_depth}"
        end

        def decode_pcm24(data)
          bytes = data.unpack("C*")
          bytes.each_slice(3).map do |b0, b1, b2|
            value = b0 | (b1 << 8) | (b2 << 16)
            value -= 0x1000000 if value.anybits?(0x800000)
            value
          end
        end

        def encode_pcm24(samples)
          bytes = samples.flat_map do |sample|
            value = sample
            value += 0x1000000 if value.negative?
            [value & 0xFF, (value >> 8) & 0xFF, (value >> 16) & 0xFF]
          end
          bytes.pack("C*")
        end

      end
    end
  end
end
