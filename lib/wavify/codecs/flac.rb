# frozen_string_literal: true

require "digest"

module Wavify
  module Codecs
    # Pure Ruby FLAC codec (metadata, decode, encode, and streaming support).
    class Flac < Base
      # Recognized filename extensions.
      EXTENSIONS = %w[.flac].freeze
      STREAMINFO_BLOCK_TYPE = 0 # :nodoc:
      STREAMINFO_LENGTH = 34 # :nodoc:
      FLAC_SYNC_CODE = 0x3FFE # :nodoc:
      # Default block size used by the FLAC stream encoder.
      DEFAULT_ENCODE_BLOCK_SIZE = 4096

      BLOCK_SIZE_CODES = { # :nodoc:
        1 => 192,
        2 => 576,
        3 => 1152,
        4 => 2304,
        5 => 4608,
        8 => 256,
        9 => 512,
        10 => 1024,
        11 => 2048,
        12 => 4096,
        13 => 8192,
        14 => 16_384,
        15 => 32_768
      }.freeze

      SAMPLE_RATE_CODES = { # :nodoc:
        1 => 88_200,
        2 => 176_400,
        3 => 192_000,
        4 => 8_000,
        5 => 16_000,
        6 => 22_050,
        7 => 24_000,
        8 => 32_000,
        9 => 44_100,
        10 => 48_000,
        11 => 96_000
      }.freeze

      SAMPLE_SIZE_CODES = { # :nodoc:
        1 => 8,
        2 => 12,
        4 => 16,
        5 => 20,
        6 => 24
      }.freeze

      # Internal bit reader used by the FLAC decoder.
      class BitReader # :nodoc:
        def initialize(io)
          @io = io
          @buffer = 0
          @bits_available = 0
        end

        def read_bits(count)
          raise InvalidFormatError, "bit count must be non-negative" unless count.is_a?(Integer) && count >= 0
          return 0 if count.zero?

          value = 0
          remaining = count
          while remaining.positive?
            fill_buffer_if_needed!

            take = [remaining, @bits_available].min
            shift = @bits_available - take
            chunk = (@buffer >> shift) & ((1 << take) - 1)
            value = (value << take) | chunk
            @bits_available -= take
            @buffer &= ((1 << @bits_available) - 1)
            remaining -= take
          end

          value
        end

        def read_signed_bits(count) # :nodoc:
          value = read_bits(count)
          sign_bit = 1 << (count - 1)
          value.nobits?(sign_bit) ? value : (value - (1 << count))
        end

        def align_to_byte # :nodoc:
          @buffer = 0
          @bits_available = 0
        end

        private

        def fill_buffer_if_needed!
          return unless @bits_available.zero?

          byte = @io.read(1)
          raise InvalidFormatError, "truncated FLAC frame" if byte.nil?

          @buffer = byte.getbyte(0)
          @bits_available = 8
        end
      end

      # Internal bit writer used by the FLAC encoder.
      class BitWriter # :nodoc:
        def initialize
          @bytes = []
          @buffer = 0
          @bits_used = 0
        end

        def write_bits(value, count)
          raise InvalidParameterError, "bit count must be a non-negative Integer" unless count.is_a?(Integer) && count >= 0
          return if count.zero?

          count.times do |shift_index|
            shift = (count - 1) - shift_index
            bit = (value >> shift) & 0x1
            @buffer = (@buffer << 1) | bit
            @bits_used += 1
            flush_byte_if_needed
          end
        end

        def write_signed_bits(value, count) # :nodoc:
          mask = (1 << count) - 1
          write_bits(value & mask, count)
        end

        def write_unary_zeros_then_one(zero_count) # :nodoc:
          zero_count.times { write_bits(0, 1) }
          write_bits(1, 1)
        end

        def write_rice_signed(value, parameter) # :nodoc:
          unsigned = value >= 0 ? (value << 1) : ((-value << 1) - 1)
          quotient = unsigned >> parameter
          remainder = parameter.zero? ? 0 : (unsigned & ((1 << parameter) - 1))

          write_unary_zeros_then_one(quotient)
          write_bits(remainder, parameter) if parameter.positive?
        end

        def align_to_byte # :nodoc:
          return if @bits_used.zero?

          @buffer <<= (8 - @bits_used)
          @bytes << @buffer
          @buffer = 0
          @bits_used = 0
        end

        def to_s # :nodoc:
          align_to_byte
          @bytes.pack("C*")
        end

        private

        def flush_byte_if_needed
          return unless @bits_used == 8

          @bytes << @buffer
          @buffer = 0
          @bits_used = 0
        end
      end

      class << self
        # @param io_or_path [String, IO]
        # @return [Boolean]
        def can_read?(io_or_path)
          return true if io_or_path.is_a?(String) && EXTENSIONS.include?(File.extname(io_or_path).downcase)
          return false unless io_or_path.respond_to?(:read)

          magic = io_or_path.read(4)
          io_or_path.rewind if io_or_path.respond_to?(:rewind)
          magic == "fLaC"
        end

        # Reads a FLAC stream and returns decoded samples.
        #
        # @param io_or_path [String, IO]
        # @param format [Wavify::Core::Format, nil]
        # @return [Wavify::Core::SampleBuffer]
        def read(io_or_path, format: nil)
          io, close_io = open_input(io_or_path)
          ensure_seekable!(io)

          metadata = parse_metadata(io)
          source_format = metadata.fetch(:format)
          samples = decode_frames(io, metadata)
          buffer = Core::SampleBuffer.new(samples, source_format)
          format ? buffer.convert(format) : buffer
        ensure
          io.close if close_io && io
        end

        # Writes a sample buffer as FLAC.
        #
        # @param io_or_path [String, IO]
        # @param sample_buffer [Wavify::Core::SampleBuffer]
        # @param format [Wavify::Core::Format]
        # @return [String, IO]
        def write(io_or_path, sample_buffer, format:)
          raise InvalidParameterError, "sample_buffer must be Core::SampleBuffer" unless sample_buffer.is_a?(Core::SampleBuffer)

          target_format = validate_encode_format!(format)
          buffer = sample_buffer.format == target_format ? sample_buffer : sample_buffer.convert(target_format)

          io, close_io = open_output(io_or_path)
          io.rewind if io.respond_to?(:rewind)
          io.truncate(0) if io.respond_to?(:truncate)
          io.write(encode_verbatim_stream(buffer, target_format))
          io.flush if io.respond_to?(:flush)
          io.rewind if io.respond_to?(:rewind)
          io_or_path
        ensure
          io.close if close_io && io
        end

        # Streams FLAC decoding as chunked sample buffers.
        #
        # @param io_or_path [String, IO]
        # @param chunk_size [Integer]
        # @return [Enumerator]
        def stream_read(io_or_path, chunk_size: 4096)
          return enum_for(__method__, io_or_path, chunk_size: chunk_size) unless block_given?
          raise InvalidParameterError, "chunk_size must be a positive Integer" unless chunk_size.is_a?(Integer) && chunk_size.positive?

          io, close_io = open_input(io_or_path)
          ensure_seekable!(io)

          metadata = parse_metadata(io)
          format = metadata.fetch(:format)
          chunk_sample_count = chunk_size * format.channels
          pending_samples = []

          each_decoded_frame_samples(io, metadata) do |frame_samples|
            pending_samples.concat(frame_samples)

            while pending_samples.length >= chunk_sample_count
              yield Core::SampleBuffer.new(pending_samples.shift(chunk_sample_count), format)
            end
          end

          yield Core::SampleBuffer.new(pending_samples, format) unless pending_samples.empty?
        ensure
          io.close if close_io && io
        end

        # Streams FLAC encoding and finalizes STREAMINFO on completion.
        #
        # @param io_or_path [String, IO]
        # @param format [Wavify::Core::Format]
        # @param block_size [Integer]
        # @param block_size_strategy [Symbol] `:per_chunk`, `:fixed`, or `:source_chunk`
        # @return [Enumerator, String, IO]
        def stream_write(io_or_path, format:, block_size: DEFAULT_ENCODE_BLOCK_SIZE, block_size_strategy: :per_chunk)
          unless block_given?
            return enum_for(
              __method__,
              io_or_path,
              format: format,
              block_size: block_size,
              block_size_strategy: block_size_strategy
            )
          end

          target_format = validate_encode_format!(format)
          stream_write_options = normalize_stream_write_options(block_size, block_size_strategy)
          io, close_io = open_output(io_or_path)
          ensure_seekable!(io)
          io.rewind if io.respond_to?(:rewind)
          io.truncate(0) if io.respond_to?(:truncate)

          header = write_stream_header(io)
          total_sample_frames = 0
          next_frame_number = 0
          encode_stats = empty_encode_stats
          header[:md5] = Digest::MD5.new
          pending_samples = []

          writer = lambda do |chunk|
            raise InvalidParameterError, "stream chunk must be Core::SampleBuffer" unless chunk.is_a?(Core::SampleBuffer)

            buffer = chunk.format == target_format ? chunk : chunk.convert(target_format)
            header.fetch(:md5).update(pcm_bytes_for_md5(buffer.samples, target_format))
            total_sample_frames += buffer.sample_frame_count

            if stream_write_options[:strategy] == :fixed
              pending_samples.concat(buffer.samples)
              fixed_chunk_sample_count = stream_write_options.fetch(:block_size) * target_format.channels

              while pending_samples.length >= fixed_chunk_sample_count
                encoded = encode_verbatim_frames(
                  pending_samples.shift(fixed_chunk_sample_count),
                  target_format,
                  start_frame_number: next_frame_number,
                  block_size: stream_write_options.fetch(:block_size)
                )
                io.write(encoded.fetch(:bytes))
                next_frame_number = encoded.fetch(:next_frame_number)
                merge_encode_stats!(encode_stats, encoded)
              end
            elsif stream_write_options[:strategy] == :source_chunk
              encoded = encode_verbatim_frames(
                buffer.samples,
                target_format,
                start_frame_number: next_frame_number,
                block_size: buffer.sample_frame_count
              )
              io.write(encoded.fetch(:bytes))
              next_frame_number = encoded.fetch(:next_frame_number)
              merge_encode_stats!(encode_stats, encoded)
            else
              encoded = encode_verbatim_frames(
                buffer.samples,
                target_format,
                start_frame_number: next_frame_number,
                block_size: stream_write_options.fetch(:block_size)
              )
              io.write(encoded.fetch(:bytes))
              next_frame_number = encoded.fetch(:next_frame_number)
              merge_encode_stats!(encode_stats, encoded)
            end
          end

          yield writer

          unless pending_samples.empty?
            encoded = encode_verbatim_frames(
              pending_samples,
              target_format,
              start_frame_number: next_frame_number,
              block_size: stream_write_options.fetch(:block_size)
            )
            io.write(encoded.fetch(:bytes))
            next_frame_number = encoded.fetch(:next_frame_number)
            merge_encode_stats!(encode_stats, encoded)
          end

          finalize_stream_header(io, header, target_format, total_sample_frames, encode_stats)
          io.flush if io.respond_to?(:flush)
          io.rewind if io.respond_to?(:rewind)
          io_or_path
        ensure
          io.close if close_io && io
        end

        # Reads FLAC metadata (including STREAMINFO-derived format/duration).
        #
        # @param io_or_path [String, IO]
        # @return [Hash]
        def metadata(io_or_path)
          io, close_io = open_input(io_or_path)
          ensure_seekable!(io)

          parse_metadata(io)
        ensure
          io.close if close_io && io
        end

        private

        def parse_metadata(io)
          io.rewind
          marker = read_exact(io, 4, "missing FLAC stream marker")
          raise InvalidFormatError, "invalid FLAC stream marker" unless marker == "fLaC"

          streaminfo = nil
          loop do
            header = read_exact(io, 4, "truncated FLAC metadata block header")
            byte0 = header.getbyte(0)
            last_block = byte0.anybits?(0x80)
            block_type = byte0 & 0x7F
            length = ((header.getbyte(1) << 16) | (header.getbyte(2) << 8) | header.getbyte(3))
            data = read_exact(io, length, "truncated FLAC metadata block")

            streaminfo = parse_streaminfo(data) if block_type == STREAMINFO_BLOCK_TYPE
            break if last_block
          end

          raise InvalidFormatError, "STREAMINFO metadata block missing" unless streaminfo

          streaminfo
        end

        def parse_streaminfo(data)
          raise InvalidFormatError, "STREAMINFO block must be 34 bytes" unless data.bytesize == STREAMINFO_LENGTH

          min_block_size, max_block_size = data[0, 4].unpack("n2")
          min_frame_size = unpack_uint24(data[4, 3])
          max_frame_size = unpack_uint24(data[7, 3])

          packed = data[10, 8].unpack1("Q>")
          sample_rate = (packed >> 44) & 0xFFFFF
          channels = ((packed >> 41) & 0x7) + 1
          bit_depth = ((packed >> 36) & 0x1F) + 1
          total_samples = packed & 0xFFFFFFFFF
          md5 = data[18, 16].unpack1("H*")

          format = Core::Format.new(
            channels: channels,
            sample_rate: sample_rate,
            bit_depth: bit_depth,
            sample_format: :pcm
          )

          {
            format: format,
            sample_frame_count: total_samples,
            duration: Core::Duration.from_samples(total_samples, sample_rate),
            min_block_size: min_block_size,
            max_block_size: max_block_size,
            min_frame_size: min_frame_size,
            max_frame_size: max_frame_size,
            md5: md5
          }
        end

        def encode_verbatim_stream(buffer, format)
          encoded_frames = encode_verbatim_frames(
            buffer.samples,
            format,
            start_frame_number: 0,
            block_size: DEFAULT_ENCODE_BLOCK_SIZE
          )
          md5_hex = pcm_md5_hex(buffer.samples, format)

          streaminfo = build_streaminfo_bytes(
            format: format,
            sample_frame_count: buffer.sample_frame_count,
            stats: encoded_frames,
            md5_hex: md5_hex
          )

          bytes = +"fLaC"
          bytes << [0x80, 0x00, 0x00, STREAMINFO_LENGTH].pack("C4")
          bytes << streaminfo
          bytes << encoded_frames.fetch(:bytes)
          bytes
        end

        def write_stream_header(io)
          io.write("fLaC")
          io.write([0x80, 0x00, 0x00, STREAMINFO_LENGTH].pack("C4"))
          streaminfo_offset = io.pos
          io.write("\x00" * STREAMINFO_LENGTH)
          { streaminfo_offset: streaminfo_offset }
        end

        def finalize_stream_header(io, header, format, total_sample_frames, encode_stats)
          file_end = io.pos
          io.seek(header.fetch(:streaminfo_offset), IO::SEEK_SET)
          io.write(
            build_streaminfo_bytes(
              format: format,
              sample_frame_count: total_sample_frames,
              stats: encode_stats,
              md5_hex: header.fetch(:md5).hexdigest
            )
          )
          io.seek(file_end, IO::SEEK_SET)
        end

        def empty_encode_stats
          {
            min_block_size: 0,
            max_block_size: 0,
            min_frame_size: 0,
            max_frame_size: 0
          }
        end

        def normalize_stream_write_options(block_size, block_size_strategy)
          strategy = block_size_strategy.to_sym
          supported = %i[per_chunk source_chunk fixed]
          unless supported.include?(strategy)
            raise InvalidParameterError, "unsupported FLAC stream_write block_size_strategy: #{block_size_strategy.inspect}"
          end

          {
            strategy: strategy,
            block_size: normalize_encode_block_size(block_size)
          }
        rescue NoMethodError
          raise InvalidParameterError, "block_size_strategy must be Symbol/String: #{block_size_strategy.inspect}"
        end

        def merge_encode_stats!(aggregate, encoded)
          current_min_block = encoded.fetch(:min_block_size)
          current_max_block = encoded.fetch(:max_block_size)
          current_min_frame = encoded.fetch(:min_frame_size)
          current_max_frame = encoded.fetch(:max_frame_size)
          return if current_max_block.zero?

          aggregate[:min_block_size] =
            aggregate[:min_block_size].zero? ? current_min_block : [aggregate[:min_block_size], current_min_block].min
          aggregate[:max_block_size] = [aggregate[:max_block_size], current_max_block].max
          aggregate[:min_frame_size] =
            aggregate[:min_frame_size].zero? ? current_min_frame : [aggregate[:min_frame_size], current_min_frame].min
          aggregate[:max_frame_size] = [aggregate[:max_frame_size], current_max_frame].max
        end

        def encode_verbatim_frames(interleaved_samples, format, start_frame_number:, block_size:)
          channels = format.channels
          samples_per_frame = channels * normalize_encode_block_size(block_size)
          bytes = +""
          frame_number = start_frame_number
          block_sizes = []
          frame_sizes = []

          interleaved_samples.each_slice(samples_per_frame) do |frame_samples|
            encoded_frame = encode_pcm_frame(frame_samples, format, frame_number: frame_number)
            bytes << encoded_frame
            block_sizes << (frame_samples.length / channels)
            frame_sizes << encoded_frame.bytesize
            frame_number += 1
          end

          {
            bytes: bytes,
            next_frame_number: frame_number,
            min_block_size: block_sizes.min || 0,
            max_block_size: block_sizes.max || 0,
            min_frame_size: frame_sizes.min || 0,
            max_frame_size: frame_sizes.max || 0
          }
        end

        def encode_pcm_frame(interleaved_samples, format, frame_number:)
          channels = format.channels
          block_size = interleaved_samples.length / channels
          raise InvalidParameterError, "FLAC frame block size must be positive" if block_size <= 0

          block_size_code, block_size_extra_bits = encode_block_size_descriptor(block_size)
          channel_samples = deinterleave_samples(interleaved_samples, channels)
          header_without_crc8 = build_frame_header_bytes(
            block_size: block_size,
            block_size_code: block_size_code,
            block_size_extra_bits: block_size_extra_bits,
            channels: channels,
            frame_number: frame_number
          )
          header_crc8 = flac_crc8(header_without_crc8)

          payload_writer = BitWriter.new
          channel_samples.each do |channel|
            write_best_subframe(payload_writer, channel, format.bit_depth)
          end
          payload_writer.align_to_byte
          payload_bytes = payload_writer.to_s

          crc16_input = header_without_crc8 + [header_crc8].pack("C") + payload_bytes
          crc16 = flac_crc16(crc16_input)

          crc16_input + [crc16].pack("n")
        end

        def write_best_subframe(writer, channel_samples, sample_size)
          selection = select_subframe_encoding(channel_samples, sample_size)

          if selection[:kind] == :fixed
            write_fixed_subframe(
              writer,
              channel_samples,
              sample_size,
              selection: selection
            )
            return
          end

          write_verbatim_subframe(writer, channel_samples, sample_size)
        end

        def select_subframe_encoding(channel_samples, sample_size)
          best = {
            kind: :verbatim,
            bit_length: verbatim_subframe_bit_length(channel_samples.length, sample_size)
          }

          max_predictor_order = [4, channel_samples.length - 1].min
          (0..max_predictor_order).each do |predictor_order|
            candidate = build_fixed_subframe_encoding(channel_samples, sample_size, predictor_order)
            next unless candidate
            next unless candidate.fetch(:bit_length) < best.fetch(:bit_length)

            best = candidate
          end

          best
        end

        def verbatim_subframe_bit_length(sample_count, sample_size)
          8 + (sample_count * sample_size)
        end

        def build_fixed_subframe_encoding(channel_samples, sample_size, predictor_order)
          residuals = fixed_subframe_residuals(channel_samples, predictor_order)
          residual_encoding = choose_residual_encoding(residuals)
          return nil unless residual_encoding

          {
            kind: :fixed,
            predictor_order: predictor_order,
            residuals: residuals,
            residual_encoding: residual_encoding,
            bit_length: 8 + (predictor_order * sample_size) + residual_encoding.fetch(:bit_length)
          }
        end

        def fixed_subframe_residuals(samples, predictor_order)
          history = samples.first(predictor_order).dup

          samples.drop(predictor_order).each_with_object([]) do |sample, residuals|
            predicted = fixed_predictor_value(history, predictor_order)
            residuals << (sample - predicted)
            history << sample
            history.shift if predictor_order.positive? && history.length > predictor_order
          end
        end

        def choose_residual_encoding(residuals)
          rice_candidates = (0..14).map do |parameter|
            {
              kind: :rice,
              parameter: parameter,
              bit_length: rice_partition0_bit_length(residuals, parameter)
            }
          end

          escape_candidate = escape_residual_encoding(residuals)
          candidates = rice_candidates
          candidates << escape_candidate if escape_candidate
          candidates.min_by { |candidate| candidate.fetch(:bit_length) }
        end

        def rice_partition0_bit_length(residuals, parameter)
          residuals.reduce(6 + 4) do |bits, residual|
            unsigned = residual >= 0 ? (residual << 1) : ((-residual << 1) - 1)
            quotient = unsigned >> parameter
            bits + quotient + 1 + parameter
          end
        end

        def escape_residual_encoding(residuals)
          raw_bits = residuals.map { |residual| signed_bit_width(residual) }.max.to_i
          return nil if raw_bits > 31

          {
            kind: :escape,
            raw_bits: raw_bits,
            bit_length: 6 + 4 + 5 + (residuals.length * raw_bits)
          }
        end

        def signed_bit_width(value)
          return 0 if value.zero?

          bits = 1
          bits += 1 until value.between?(-(1 << (bits - 1)), (1 << (bits - 1)) - 1)
          bits
        end

        def write_fixed_subframe(writer, channel_samples, sample_size, selection:)
          predictor_order = selection.fetch(:predictor_order)
          residual_encoding = selection.fetch(:residual_encoding)
          residuals = selection.fetch(:residuals)

          writer.write_bits(0, 1) # padding bit
          writer.write_bits(8 + predictor_order, 6)
          writer.write_bits(0, 1) # no wasted bits

          channel_samples.first(predictor_order).each { |sample| writer.write_signed_bits(sample, sample_size) }
          write_partition0_residuals(writer, residual_encoding, residuals)
        end

        def write_partition0_residuals(writer, residual_encoding, residuals)
          if residual_encoding[:kind] == :rice
            writer.write_bits(0, 2) # Rice
            writer.write_bits(0, 4) # partition order = 0
            writer.write_bits(residual_encoding.fetch(:parameter), 4)
            residuals.each { |residual| writer.write_rice_signed(residual, residual_encoding.fetch(:parameter)) }
            return
          end

          writer.write_bits(0, 2) # Rice coding method family
          writer.write_bits(0, 4) # partition order = 0
          writer.write_bits(0xF, 4) # escape code
          raw_bits = residual_encoding.fetch(:raw_bits)
          writer.write_bits(raw_bits, 5)
          residuals.each { |residual| writer.write_signed_bits(residual, raw_bits) } if raw_bits.positive?
        end

        def build_frame_header_bytes(block_size:, block_size_code:, block_size_extra_bits:, channels:, frame_number:)
          writer = BitWriter.new
          writer.write_bits(FLAC_SYNC_CODE, 14)
          writer.write_bits(0, 1) # reserved
          writer.write_bits(0, 1) # fixed-blocksize stream
          writer.write_bits(block_size_code, 4)
          writer.write_bits(0, 4) # sample rate from STREAMINFO
          writer.write_bits(channels - 1, 4) # independent channels
          writer.write_bits(0, 3) # sample size from STREAMINFO
          writer.write_bits(0, 1) # reserved
          write_utf8_uint(writer, frame_number)
          writer.write_bits(block_size - 1, block_size_extra_bits) if block_size_extra_bits.positive?
          writer.align_to_byte
          writer.to_s
        end

        def write_verbatim_subframe(writer, channel_samples, sample_size)
          writer.write_bits(0, 1) # padding bit
          writer.write_bits(1, 6) # verbatim subframe type
          writer.write_bits(0, 1) # no wasted bits
          channel_samples.each { |sample| writer.write_signed_bits(sample, sample_size) }
        end

        def deinterleave_samples(interleaved_samples, channels)
          channel_samples = Array.new(channels) { [] }

          interleaved_samples.each_slice(channels) do |frame|
            channels.times do |channel_index|
              channel_samples[channel_index] << frame.fetch(channel_index)
            end
          end

          channel_samples
        end

        def encode_block_size_descriptor(block_size)
          raise UnsupportedFormatError, "FLAC block size exceeds 65536 samples" if block_size > 65_536

          if block_size <= 256
            [6, 8]
          else
            [7, 16]
          end
        end

        def write_utf8_uint(writer, value)
          raise InvalidParameterError, "FLAC frame number must be non-negative Integer" unless value.is_a?(Integer) && value >= 0

          if value <= 0x7F
            writer.write_bits(value, 8)
            return
          end

          payload_bits = Math.log2(value + 1).floor + 1
          length = 2
          length += 1 while payload_capacity_for_utf8_uint(length) < payload_bits
          raise UnsupportedFormatError, "FLAC frame number is too large to encode" if length > 7

          bytes = Array.new(length, 0)
          remaining = value
          (length - 1).downto(1) do |index|
            bytes[index] = 0x80 | (remaining & 0x3F)
            remaining >>= 6
          end

          prefix = ((1 << length) - 1) << (8 - length)
          bytes[0] = prefix | remaining

          bytes.each { |byte| writer.write_bits(byte, 8) }
        end

        def payload_capacity_for_utf8_uint(length)
          (7 - length) + (6 * (length - 1))
        end

        def normalize_encode_block_size(block_size)
          size = block_size.to_i
          raise InvalidParameterError, "FLAC block_size must be a positive Integer" unless size.positive?

          [size, 65_536].min
        end

        def build_streaminfo_bytes(format:, sample_frame_count:, stats:, md5_hex:)
          raise UnsupportedFormatError, "FLAC total sample count exceeds 36-bit STREAMINFO limit" if sample_frame_count > 0xFFFFFFFFF

          min_block_size = stats.fetch(:min_block_size)
          max_block_size = stats.fetch(:max_block_size)
          min_frame_size = stats.fetch(:min_frame_size)
          max_frame_size = stats.fetch(:max_frame_size)
          md5_bytes = [md5_hex].pack("H*")
          raise InvalidParameterError, "md5_hex must be 32 hex characters" unless md5_bytes.bytesize == 16

          packed = ((format.sample_rate & 0xFFFFF) << 44) |
                   (((format.channels - 1) & 0x7) << 41) |
                   (((format.bit_depth - 1) & 0x1F) << 36) |
                   (sample_frame_count & 0xFFFFFFFFF)

          [min_block_size, max_block_size].pack("n2") +
            pack_uint24(min_frame_size) +
            pack_uint24(max_frame_size) +
            [packed].pack("Q>") +
            md5_bytes
        end

        def pcm_md5_hex(samples, format)
          Digest::MD5.hexdigest(pcm_bytes_for_md5(samples, format))
        end

        def pcm_bytes_for_md5(samples, format)
          case format.bit_depth
          when 8
            samples.pack("c*")
          when 16
            samples.pack("s<*")
          when 24
            encode_pcm24_le(samples)
          when 32
            samples.pack("l<*")
          else
            raise UnsupportedFormatError, "unsupported FLAC MD5 PCM bit depth: #{format.bit_depth}"
          end
        end

        def encode_pcm24_le(samples)
          bytes = samples.flat_map do |sample|
            value = sample
            value += 0x1000000 if value.negative?
            [value & 0xFF, (value >> 8) & 0xFF, (value >> 16) & 0xFF]
          end
          bytes.pack("C*")
        end

        def flac_crc8(data)
          crc = 0
          data.each_byte do |byte|
            crc ^= byte
            8.times do
              crc = crc.anybits?(0x80) ? ((crc << 1) ^ 0x07) : (crc << 1)
              crc &= 0xFF
            end
          end
          crc
        end

        def flac_crc16(data)
          crc = 0
          data.each_byte do |byte|
            crc ^= (byte << 8)
            8.times do
              crc = crc.anybits?(0x8000) ? ((crc << 1) ^ 0x8005) : (crc << 1)
              crc &= 0xFFFF
            end
          end
          crc
        end

        def pack_uint24(value)
          raise InvalidParameterError, "value must fit in uint24" unless value.is_a?(Integer) && value.between?(0, 0xFFFFFF)

          [(value >> 16) & 0xFF, (value >> 8) & 0xFF, value & 0xFF].pack("C3")
        end

        def validate_encode_format!(format)
          raise InvalidParameterError, "format must be Core::Format" unless format.is_a?(Core::Format)
          raise UnsupportedFormatError, "FLAC encoding only supports PCM sample format" unless format.sample_format == :pcm
          raise UnsupportedFormatError, "FLAC encoding supports 1..8 channels" unless format.channels.between?(1, 8)
          raise UnsupportedFormatError, "FLAC encoding supports up to 32-bit PCM" if format.bit_depth > 32

          format
        end

        def decode_frames(io, metadata)
          decoded_samples = []
          each_decoded_frame_samples(io, metadata) { |frame_samples| decoded_samples.concat(frame_samples) }
          decoded_samples
        end

        def each_decoded_frame_samples(io, metadata)
          return enum_for(__method__, io, metadata) unless block_given?

          format = metadata.fetch(:format)
          remaining_frames = metadata[:sample_frame_count]
          bounded_total = remaining_frames.is_a?(Integer) && remaining_frames.positive?

          until io.eof?
            break if bounded_total && remaining_frames <= 0

            next_byte = io.read(1)
            break if next_byte.nil?

            io.seek(-1, IO::SEEK_CUR)
            frame_samples = decode_frame(io, metadata)

            if bounded_total
              max_samples = remaining_frames * format.channels
              frame_samples = frame_samples.first(max_samples) if frame_samples.length > max_samples

              decoded_frame_count = frame_samples.length / format.channels
              remaining_frames -= decoded_frame_count
            end

            yield frame_samples unless frame_samples.empty?
          end

          return unless bounded_total && remaining_frames.positive?

          raise InvalidFormatError, "decoded FLAC samples are shorter than STREAMINFO total sample count"
        end

        def decode_frame(io, metadata)
          bit_reader = BitReader.new(io)
          frame_header = parse_frame_header(bit_reader, metadata)
          channel_samples = decode_subframes(bit_reader, frame_header)
          channel_samples = restore_channel_assignment(channel_samples, frame_header)
          bit_reader.align_to_byte
          _crc16 = bit_reader.read_bits(16)

          interleave_channels(channel_samples, frame_header.fetch(:block_size), frame_header.fetch(:channels))
        end

        def parse_frame_header(bit_reader, metadata)
          sync = bit_reader.read_bits(14)
          raise InvalidFormatError, "invalid FLAC frame sync code" unless sync == FLAC_SYNC_CODE

          reserved = bit_reader.read_bits(1)
          raise InvalidFormatError, "reserved FLAC frame header bit must be 0" unless reserved.zero?

          blocking_strategy = bit_reader.read_bits(1)
          raise UnsupportedFormatError, "FLAC variable-blocksize frames are not supported yet" unless blocking_strategy.zero?

          block_size_code = bit_reader.read_bits(4)
          sample_rate_code = bit_reader.read_bits(4)
          channel_assignment = bit_reader.read_bits(4)
          sample_size_code = bit_reader.read_bits(3)
          reserved2 = bit_reader.read_bits(1)
          raise InvalidFormatError, "reserved FLAC frame header bit must be 0" unless reserved2.zero?

          _frame_number = read_utf8_uint(bit_reader)
          block_size = decode_block_size(block_size_code, bit_reader)
          sample_rate = decode_sample_rate(sample_rate_code, bit_reader, metadata.fetch(:format).sample_rate)
          sample_size = decode_sample_size(sample_size_code, metadata.fetch(:format).bit_depth)
          _crc8 = bit_reader.read_bits(8)

          channels = decode_channel_count(channel_assignment, metadata.fetch(:format).channels)

          {
            block_size: block_size,
            sample_rate: sample_rate,
            sample_size: sample_size,
            channels: channels,
            channel_assignment: channel_assignment
          }
        end

        def read_utf8_uint(bit_reader)
          first = bit_reader.read_bits(8)
          return first if first.nobits?(0x80)

          mask = 0x80
          length = 0
          while first.anybits?(mask)
            length += 1
            mask >>= 1
          end
          raise InvalidFormatError, "invalid UTF-8 integer in FLAC frame header" if length < 2 || length > 7

          value_mask = (1 << (7 - length)) - 1
          value = first & value_mask
          (length - 1).times do
            byte = bit_reader.read_bits(8)
            raise InvalidFormatError, "invalid UTF-8 continuation byte in FLAC frame header" unless (byte & 0xC0) == 0x80

            value = (value << 6) | (byte & 0x3F)
          end
          value
        end

        def decode_block_size(code, bit_reader)
          case code
          when 0
            raise InvalidFormatError, "reserved FLAC block size code"
          when 6
            bit_reader.read_bits(8) + 1
          when 7
            bit_reader.read_bits(16) + 1
          else
            BLOCK_SIZE_CODES.fetch(code)
          end
        rescue KeyError
          raise UnsupportedFormatError, "unsupported FLAC block size code: #{code}"
        end

        def decode_sample_rate(code, bit_reader, stream_sample_rate)
          case code
          when 0
            stream_sample_rate
          when 12
            bit_reader.read_bits(8) * 1000
          when 13
            bit_reader.read_bits(16)
          when 14
            bit_reader.read_bits(16) * 10
          else
            SAMPLE_RATE_CODES.fetch(code)
          end
        rescue KeyError
          raise UnsupportedFormatError, "unsupported FLAC sample rate code: #{code}"
        end

        def decode_sample_size(code, stream_bit_depth)
          return stream_bit_depth if code.zero?

          SAMPLE_SIZE_CODES.fetch(code)
        rescue KeyError
          raise UnsupportedFormatError, "unsupported FLAC sample size code: #{code}"
        end

        def decode_channel_count(channel_assignment, stream_channels)
          case channel_assignment
          when 0..7
            channels = channel_assignment + 1
            raise InvalidFormatError, "FLAC frame channel count does not match STREAMINFO" if channels != stream_channels

            channels
          when 8..10
            raise InvalidFormatError, "FLAC side/mid channel assignments require stereo STREAMINFO" unless stream_channels == 2

            2
          else
            raise InvalidFormatError, "reserved FLAC channel assignment: #{channel_assignment}"
          end
        end

        def decode_subframes(bit_reader, frame_header)
          channels = frame_header.fetch(:channels)
          block_size = frame_header.fetch(:block_size)
          sample_sizes = subframe_sample_sizes(frame_header)

          Array.new(channels) do |channel_index|
            decode_subframe(bit_reader, block_size: block_size, sample_size: sample_sizes.fetch(channel_index))
          end
        end

        def subframe_sample_sizes(frame_header)
          sample_size = frame_header.fetch(:sample_size)

          case frame_header.fetch(:channel_assignment)
          when 8, 10
            [sample_size, sample_size + 1]
          when 9
            [sample_size + 1, sample_size]
          else
            Array.new(frame_header.fetch(:channels), sample_size)
          end
        end

        def decode_subframe(bit_reader, block_size:, sample_size:)
          padding = bit_reader.read_bits(1)
          raise InvalidFormatError, "FLAC subframe padding bit must be 0" unless padding.zero?

          subframe_type = bit_reader.read_bits(6)
          wasted_bits_flag = bit_reader.read_bits(1)
          wasted_bits = wasted_bits_flag.zero? ? 0 : (read_unary_zero_run(bit_reader) + 1)
          effective_sample_size = sample_size - wasted_bits
          raise InvalidFormatError, "invalid FLAC wasted bits count" unless effective_sample_size.positive?

          decoded = case subframe_type
                    when 0
                      value = bit_reader.read_signed_bits(effective_sample_size)
                      Array.new(block_size, value)
                    when 1
                      Array.new(block_size) { bit_reader.read_signed_bits(effective_sample_size) }
                    when 8..12
                      predictor_order = subframe_type - 8
                      decode_fixed_subframe(
                        bit_reader,
                        block_size: block_size,
                        sample_size: effective_sample_size,
                        predictor_order: predictor_order
                      )
                    when 32..63
                      predictor_order = (subframe_type & 0x1F) + 1
                      decode_lpc_subframe(
                        bit_reader,
                        block_size: block_size,
                        sample_size: effective_sample_size,
                        predictor_order: predictor_order
                      )
                    else
                      raise UnsupportedFormatError, "unsupported FLAC subframe type: #{subframe_type}"
                    end

          return decoded if wasted_bits.zero?

          decoded.map { |sample| sample << wasted_bits }
        end

        def decode_fixed_subframe(bit_reader, block_size:, sample_size:, predictor_order:)
          raise InvalidFormatError, "FLAC fixed predictor order exceeds block size" if predictor_order > block_size

          warmup = Array.new(predictor_order) { bit_reader.read_signed_bits(sample_size) }
          residuals = decode_residuals(
            bit_reader,
            block_size: block_size,
            predictor_order: predictor_order
          )

          reconstruct_fixed_subframe(warmup, residuals, predictor_order)
        end

        def decode_lpc_subframe(bit_reader, block_size:, sample_size:, predictor_order:)
          raise InvalidFormatError, "FLAC LPC predictor order exceeds block size" if predictor_order > block_size

          warmup = Array.new(predictor_order) { bit_reader.read_signed_bits(sample_size) }

          precision_minus_one = bit_reader.read_bits(4)
          raise InvalidFormatError, "invalid FLAC LPC coefficient precision" if precision_minus_one == 0xF

          coefficient_precision = precision_minus_one + 1
          qlp_shift = bit_reader.read_signed_bits(5)
          coefficients = Array.new(predictor_order) { bit_reader.read_signed_bits(coefficient_precision) }
          residuals = decode_residuals(
            bit_reader,
            block_size: block_size,
            predictor_order: predictor_order
          )

          reconstruct_lpc_subframe(warmup, residuals, coefficients, qlp_shift)
        end

        def decode_residuals(bit_reader, block_size:, predictor_order:)
          coding_method = bit_reader.read_bits(2)
          partition_order = bit_reader.read_bits(4)
          partition_count = 1 << partition_order
          raise InvalidFormatError, "invalid FLAC residual partitioning" if partition_count.zero?
          raise InvalidFormatError, "FLAC block size must be divisible by residual partitions" unless (block_size % partition_count).zero?

          partition_block_size = block_size / partition_count
          case coding_method
          when 0
            decode_rice_partitions(
              bit_reader,
              partition_count: partition_count,
              partition_block_size: partition_block_size,
              predictor_order: predictor_order,
              coding: { parameter_bits: 4, escape_parameter: 0xF }
            )
          when 1
            decode_rice_partitions(
              bit_reader,
              partition_count: partition_count,
              partition_block_size: partition_block_size,
              predictor_order: predictor_order,
              coding: { parameter_bits: 5, escape_parameter: 0x1F }
            )
          else
            raise UnsupportedFormatError, "unsupported FLAC residual coding method: #{coding_method}"
          end
        end

        def decode_rice_partitions(bit_reader, partition_count:, partition_block_size:, predictor_order:, coding:)
          residuals = []
          parameter_bits = coding.fetch(:parameter_bits)
          escape_parameter = coding.fetch(:escape_parameter)

          partition_count.times do |partition_index|
            sample_count = partition_block_size
            sample_count -= predictor_order if partition_index.zero?
            raise InvalidFormatError, "invalid FLAC residual partition sample count" if sample_count.negative?

            parameter = bit_reader.read_bits(parameter_bits)
            if parameter == escape_parameter
              raw_bits = bit_reader.read_bits(5)
              sample_count.times { residuals << (raw_bits.zero? ? 0 : bit_reader.read_signed_bits(raw_bits)) }
            else
              sample_count.times { residuals << read_rice_signed(bit_reader, parameter) }
            end
          end

          residuals
        end

        def read_rice_signed(bit_reader, parameter)
          quotient = read_unary_zero_run(bit_reader)

          remainder = parameter.zero? ? 0 : bit_reader.read_bits(parameter)
          unsigned = (quotient << parameter) | remainder
          unsigned.even? ? (unsigned >> 1) : -((unsigned + 1) >> 1)
        end

        def read_unary_zero_run(bit_reader)
          count = 0
          count += 1 while bit_reader.read_bits(1).zero?
          count
        end

        def reconstruct_fixed_subframe(warmup, residuals, predictor_order)
          samples = warmup.dup
          residuals.each do |residual|
            predicted = fixed_predictor_value(samples, predictor_order)
            samples << (predicted + residual)
          end
          samples
        end

        def reconstruct_lpc_subframe(warmup, residuals, coefficients, qlp_shift)
          samples = warmup.dup

          residuals.each do |residual|
            sum = 0
            coefficients.each_with_index do |coefficient, index|
              sum += coefficient * samples[-1 - index]
            end

            predicted = qlp_shift.negative? ? (sum << -qlp_shift) : (sum >> qlp_shift)
            samples << (predicted + residual)
          end

          samples
        end

        def fixed_predictor_value(samples, predictor_order)
          case predictor_order
          when 0
            0
          when 1
            samples[-1]
          when 2
            (2 * samples[-1]) - samples[-2]
          when 3
            (3 * samples[-1]) - (3 * samples[-2]) + samples[-3]
          when 4
            (4 * samples[-1]) - (6 * samples[-2]) + (4 * samples[-3]) - samples[-4]
          else
            raise UnsupportedFormatError, "unsupported FLAC fixed predictor order: #{predictor_order}"
          end
        end

        def interleave_channels(channel_samples, block_size, channels)
          samples = Array.new(block_size * channels)

          block_size.times do |frame_index|
            channels.times do |channel_index|
              samples[(frame_index * channels) + channel_index] = channel_samples[channel_index][frame_index]
            end
          end

          samples
        end

        def restore_channel_assignment(channel_samples, frame_header)
          assignment = frame_header.fetch(:channel_assignment)
          return channel_samples if assignment <= 7

          left_or_side = channel_samples.fetch(0)
          right_or_side = channel_samples.fetch(1)

          case assignment
          when 8 # left + side
            left = left_or_side
            side = right_or_side
            right = left.zip(side).map { |l, s| l - s }
            [left, right]
          when 9 # side + right
            side = left_or_side
            right = right_or_side
            left = side.zip(right).map { |s, r| s + r }
            [left, right]
          when 10 # mid + side
            mid = left_or_side
            side = right_or_side
            left = []
            right = []

            mid.each_with_index do |mid_sample, index|
              side_sample = side.fetch(index)
              adjusted_mid = (mid_sample << 1) | (side_sample & 0x1)
              left << ((adjusted_mid + side_sample) >> 1)
              right << ((adjusted_mid - side_sample) >> 1)
            end

            [left, right]
          else
            raise InvalidFormatError, "unsupported FLAC channel assignment: #{assignment}"
          end
        end

        def unpack_uint24(bytes)
          bytes.unpack("C3").then { |b0, b1, b2| (b0 << 16) | (b1 << 8) | b2 }
        end

        def read_exact(io, size, message)
          data = io.read(size)
          raise InvalidFormatError, message if data.nil? || data.bytesize != size

          data
        end

        def ensure_seekable!(io)
          return if io.respond_to?(:seek) && io.respond_to?(:rewind)

          raise StreamError, "FLAC codec requires seekable IO"
        end

        def open_input(io_or_path)
          return [io_or_path, false] if io_or_path.respond_to?(:read)
          raise InvalidParameterError, "input path must be String or IO: #{io_or_path.inspect}" unless io_or_path.is_a?(String)

          [File.open(io_or_path, "rb"), true]
        rescue Errno::ENOENT
          raise InvalidFormatError, "input file not found: #{io_or_path}"
        end

        def open_output(io_or_path)
          return [io_or_path, false] if io_or_path.respond_to?(:write)
          raise InvalidParameterError, "output path must be String or IO: #{io_or_path.inspect}" unless io_or_path.is_a?(String)

          [File.open(io_or_path, "wb"), true]
        end
      end
    end
  end
end
