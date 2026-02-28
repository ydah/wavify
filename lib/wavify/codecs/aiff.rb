# frozen_string_literal: true

module Wavify
  module Codecs
    # AIFF codec for PCM audio (AIFC is not currently supported).
    class Aiff < Base
      # Recognized filename extensions.
      EXTENSIONS = %w[.aiff .aif].freeze

      class << self
        # @param io_or_path [String, IO]
        # @return [Boolean]
        def can_read?(io_or_path)
          if io_or_path.is_a?(String)
            return true if EXTENSIONS.include?(File.extname(io_or_path).downcase)
            return false unless File.file?(io_or_path)
          end

          io, close_io = open_input(io_or_path)
          return false unless io

          header = io.read(12)
          io.rewind if io.respond_to?(:rewind)
          header&.start_with?("FORM") && header[8, 4] == "AIFF"
        ensure
          io.close if close_io && io
        end

        # Reads an AIFF file/IO into a sample buffer.
        #
        # @param io_or_path [String, IO]
        # @param format [Wavify::Core::Format, nil]
        # @return [Wavify::Core::SampleBuffer]
        def read(io_or_path, format: nil)
          io, close_io = open_input(io_or_path)
          ensure_seekable!(io)

          info = parse_chunks(io)
          source_format = info.fetch(:format)
          samples = read_sound_data(io, info, source_format)
          buffer = Core::SampleBuffer.new(samples, source_format)
          format ? buffer.convert(format) : buffer
        ensure
          io.close if close_io && io
        end

        # Writes a sample buffer as AIFF (PCM only).
        #
        # @param io_or_path [String, IO]
        # @param sample_buffer [Wavify::Core::SampleBuffer]
        # @param format [Wavify::Core::Format, nil]
        # @return [String, IO]
        def write(io_or_path, sample_buffer, format: nil)
          raise InvalidParameterError, "sample_buffer must be Core::SampleBuffer" unless sample_buffer.is_a?(Core::SampleBuffer)

          target_format = format || sample_buffer.format
          raise InvalidParameterError, "format must be Core::Format" unless target_format.is_a?(Core::Format)
          raise UnsupportedFormatError, "AIFF writer supports PCM only" unless target_format.sample_format == :pcm

          buffer = sample_buffer.format == target_format ? sample_buffer : sample_buffer.convert(target_format)

          io, close_io = open_output(io_or_path)
          io.rewind if io.respond_to?(:rewind)
          io.truncate(0) if io.respond_to?(:truncate)

          sample_frames = buffer.sample_frame_count
          comm_chunk = build_comm_chunk(target_format, sample_frames)
          ssnd_chunk = build_ssnd_chunk(buffer.samples, target_format)
          form_size = 4 + chunk_size(comm_chunk) + chunk_size(ssnd_chunk)

          io.write("FORM")
          io.write([form_size].pack("N"))
          io.write("AIFF")
          write_chunk(io, "COMM", comm_chunk)
          write_chunk(io, "SSND", ssnd_chunk)
          io.flush if io.respond_to?(:flush)
          io.rewind if io.respond_to?(:rewind)

          io_or_path
        ensure
          io.close if close_io && io
        end

        # Streams AIFF decoding in frame chunks.
        #
        # @param io_or_path [String, IO]
        # @param chunk_size [Integer]
        # @return [Enumerator]
        def stream_read(io_or_path, chunk_size: 4096)
          return enum_for(__method__, io_or_path, chunk_size: chunk_size) unless block_given?
          raise InvalidParameterError, "chunk_size must be a positive Integer" unless chunk_size.is_a?(Integer) && chunk_size.positive?

          io, close_io = open_input(io_or_path)
          ensure_seekable!(io)

          info = parse_chunks(io)
          format = info.fetch(:format)
          bytes_per_frame = format.block_align
          remaining = info.fetch(:sound_data_size)
          io.seek(info.fetch(:sound_data_offset), IO::SEEK_SET)

          while remaining.positive?
            bytes = [remaining, bytes_per_frame * chunk_size].min
            chunk_data = read_exact(io, bytes, "truncated SSND data")
            yield Core::SampleBuffer.new(decode_samples(chunk_data, format), format)
            remaining -= bytes
          end
        ensure
          io.close if close_io && io
        end

        # Streams AIFF encoding through a yielded chunk writer.
        #
        # @param io_or_path [String, IO]
        # @param format [Wavify::Core::Format]
        # @return [Enumerator, String, IO]
        def stream_write(io_or_path, format:)
          return enum_for(__method__, io_or_path, format: format) unless block_given?
          raise InvalidParameterError, "format must be Core::Format" unless format.is_a?(Core::Format)
          raise UnsupportedFormatError, "AIFF stream writer supports PCM only" unless format.sample_format == :pcm

          chunks = []
          sample_frames = 0
          writer = lambda do |buffer|
            raise InvalidParameterError, "stream chunk must be Core::SampleBuffer" unless buffer.is_a?(Core::SampleBuffer)

            converted = buffer.format == format ? buffer : buffer.convert(format)
            chunks << encode_samples(converted.samples, format)
            sample_frames += converted.sample_frame_count
          end
          yield writer

          data = chunks.join
          temp_buffer = Core::SampleBuffer.new(decode_samples(data, format), format)
          write(io_or_path, temp_buffer, format: format)
        end

        # Reads AIFF metadata without decoding the full audio payload.
        #
        # @param io_or_path [String, IO]
        # @return [Hash]
        def metadata(io_or_path)
          io, close_io = open_input(io_or_path)
          ensure_seekable!(io)

          info = parse_chunks(io)
          format = info.fetch(:format)
          sample_frame_count = info.fetch(:sample_frame_count)

          {
            format: format,
            sample_frame_count: sample_frame_count,
            duration: Core::Duration.from_samples(sample_frame_count, format.sample_rate)
          }
        ensure
          io.close if close_io && io
        end

        private

        def parse_chunks(io)
          io.rewind
          header = read_exact(io, 12, "missing FORM header")
          raise InvalidFormatError, "invalid AIFF header" unless header.start_with?("FORM")

          form_type = header[8, 4]
          raise UnsupportedFormatError, "AIFC is not supported yet" if form_type == "AIFC"
          raise InvalidFormatError, "invalid AIFF form type" unless form_type == "AIFF"

          info = {
            format: nil,
            sample_frame_count: nil,
            sound_data_offset: nil,
            sound_data_size: nil
          }

          until io.eof?
            chunk_header = io.read(8)
            break if chunk_header.nil?
            raise InvalidFormatError, "truncated AIFF chunk header" unless chunk_header.bytesize == 8

            chunk_id = chunk_header[0, 4]
            chunk_size = chunk_header[4, 4].unpack1("N")

            case chunk_id
            when "COMM"
              chunk_data = read_exact(io, chunk_size, "truncated COMM chunk")
              parse_comm_chunk(chunk_data, info)
            when "SSND"
              offset, = read_exact(io, 8, "truncated SSND header").unpack("N2")
              skip_bytes(io, offset)
              sound_data_size = chunk_size - 8 - offset
              raise InvalidFormatError, "invalid SSND chunk size" if sound_data_size.negative?

              info[:sound_data_offset] = io.pos
              info[:sound_data_size] = sound_data_size
              skip_bytes(io, sound_data_size)
            else
              skip_bytes(io, chunk_size)
            end

            io.read(1) if chunk_size.odd?
          end

          raise InvalidFormatError, "COMM chunk missing" unless info[:format]
          raise InvalidFormatError, "SSND chunk missing" unless info[:sound_data_offset] && info[:sound_data_size]

          info[:sample_frame_count] = info[:sound_data_size] / info[:format].block_align if info[:sample_frame_count].nil?

          if (info[:sound_data_size] % info[:format].block_align) != 0
            raise InvalidFormatError, "SSND data size is not aligned to frame size"
          end

          info
        end

        def parse_comm_chunk(chunk, info)
          raise InvalidFormatError, "COMM chunk too small" if chunk.bytesize < 18

          channels, sample_frames, bit_depth = chunk.unpack("n N n")
          sample_rate = decode_extended80(chunk[8, 10])
          rounded_rate = sample_rate.round

          format = Core::Format.new(
            channels: channels,
            sample_rate: rounded_rate,
            bit_depth: bit_depth,
            sample_format: :pcm
          )

          info[:format] = format
          info[:sample_frame_count] = sample_frames
        end

        def read_sound_data(io, info, format)
          io.seek(info.fetch(:sound_data_offset), IO::SEEK_SET)
          data = read_exact(io, info.fetch(:sound_data_size), "truncated SSND data")
          decode_samples(data, format)
        end

        def decode_samples(data, format)
          case format.bit_depth
          when 8
            data.unpack("c*")
          when 16
            data.unpack("s>*")
          when 24
            decode_pcm24_be(data)
          when 32
            data.unpack("l>*")
          else
            raise UnsupportedFormatError, "unsupported AIFF bit depth: #{format.bit_depth}"
          end
        end

        def encode_samples(samples, format)
          case format.bit_depth
          when 8
            samples.pack("c*")
          when 16
            samples.pack("s>*")
          when 24
            encode_pcm24_be(samples)
          when 32
            samples.pack("l>*")
          else
            raise UnsupportedFormatError, "unsupported AIFF bit depth: #{format.bit_depth}"
          end
        end

        def decode_pcm24_be(data)
          bytes = data.unpack("C*")
          bytes.each_slice(3).map do |b0, b1, b2|
            value = (b0 << 16) | (b1 << 8) | b2
            value -= 0x1000000 if value.anybits?(0x800000)
            value
          end
        end

        def encode_pcm24_be(samples)
          bytes = samples.flat_map do |sample|
            value = sample.to_i
            value += 0x1000000 if value.negative?
            [(value >> 16) & 0xFF, (value >> 8) & 0xFF, value & 0xFF]
          end
          bytes.pack("C*")
        end

        def build_comm_chunk(format, sample_frames)
          [format.channels, sample_frames, format.bit_depth].pack("n N n") + encode_extended80(format.sample_rate.to_f)
        end

        def build_ssnd_chunk(samples, format)
          [0, 0].pack("N2") + encode_samples(samples, format)
        end

        def write_chunk(io, chunk_id, chunk_data)
          io.write(chunk_id)
          io.write([chunk_data.bytesize].pack("N"))
          io.write(chunk_data)
          io.write("\x00") if chunk_data.bytesize.odd?
        end

        def chunk_size(chunk_data)
          8 + chunk_data.bytesize + (chunk_data.bytesize.odd? ? 1 : 0)
        end

        def decode_extended80(bytes)
          raise InvalidFormatError, "invalid 80-bit float" unless bytes && bytes.bytesize == 10

          exponent_word = bytes[0, 2].unpack1("n")
          return 0.0 if exponent_word.zero?

          sign = exponent_word.nobits?(0x8000) ? 1.0 : -1.0
          exponent = (exponent_word & 0x7FFF) - 16_383
          mantissa = bytes[2, 8].unpack1("Q>")
          sign * mantissa * (2.0**(exponent - 63))
        end

        def encode_extended80(value)
          raise InvalidParameterError, "AIFF sample_rate must be positive" unless value.is_a?(Numeric) && value.positive?

          fraction, exponent = Math.frexp(value.to_f) # value = fraction * 2**exponent, fraction in [0.5,1)
          exponent_word = (exponent - 1) + 16_383
          mantissa = ((fraction * 2.0) * (2**63)).round

          if mantissa >= (2**64)
            mantissa >>= 1
            exponent_word += 1
          end

          [exponent_word, mantissa].pack("n Q>")
        end

      end
    end
  end
end
