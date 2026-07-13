# frozen_string_literal: true

require "digest"

module Wavify
  module Codecs
    # Pure Ruby FLAC codec (metadata, decode, encode, and streaming support).
    class Flac < Base
      # Recognized filename extensions.
      EXTENSIONS = %w[.flac].freeze
      STREAMINFO_BLOCK_TYPE = 0 # :nodoc:
      SEEKTABLE_BLOCK_TYPE = 3 # :nodoc:
      VORBIS_COMMENT_BLOCK_TYPE = 4 # :nodoc:
      STREAMINFO_LENGTH = 34 # :nodoc:
      FLAC_SYNC_CODE = 0x3FFE # :nodoc:
      # Default block size used by the FLAC stream encoder.
      DEFAULT_ENCODE_BLOCK_SIZE = 4096
      COMPRESSION_BLOCK_SIZES = [1024, 2048, 4096, 4096, 4096, 8192, 8192, 16_384, 16_384].freeze # :nodoc:

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
        # @param block_size [Integer]
        # @return [String, IO]
        def write(io_or_path, sample_buffer, format:, block_size: DEFAULT_ENCODE_BLOCK_SIZE, compression_level: nil,
                  comments: nil, stereo_coding: :auto, predictor: :auto, **codec_options)
          validate_no_codec_options!(codec_options, operation: "FLAC write")
          raise InvalidParameterError, "sample_buffer must be Core::SampleBuffer" unless sample_buffer.is_a?(Core::SampleBuffer)

          target_format = validate_encode_format!(format)
          buffer = sample_buffer.format == target_format ? sample_buffer : sample_buffer.convert(target_format)
          target_block_size = normalize_write_block_size(block_size, compression_level)
          vorbis_comments = normalize_vorbis_comments(comments)
          normalized_stereo_coding = normalize_stereo_coding!(stereo_coding)
          normalized_predictor = normalize_predictor!(predictor)

          io, close_io = open_output(io_or_path)
          io.rewind if io.respond_to?(:rewind)
          io.truncate(0) if close_io && io.respond_to?(:truncate)
          io.write(
            encode_verbatim_stream(
              buffer,
              target_format,
              block_size: target_block_size,
              comments: vorbis_comments,
              stereo_coding: normalized_stereo_coding,
              predictor: normalized_predictor
            )
          )
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
          pending_offset = 0

          each_decoded_frame_samples(io, metadata) do |frame_samples|
            pending_samples.concat(frame_samples)

            while (pending_samples.length - pending_offset) >= chunk_sample_count
              yield Core::SampleBuffer.new(pending_samples.slice(pending_offset, chunk_sample_count), format)
              pending_offset += chunk_sample_count
            end

            if pending_offset >= chunk_sample_count * 8
              pending_samples = pending_samples.slice(pending_offset, pending_samples.length - pending_offset) || []
              pending_offset = 0
            end
          end

          remaining = pending_samples.length - pending_offset
          yield Core::SampleBuffer.new(pending_samples.slice(pending_offset, remaining), format) if remaining.positive?
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
        def stream_write(io_or_path, format:, block_size: DEFAULT_ENCODE_BLOCK_SIZE, block_size_strategy: :per_chunk,
                         compression_level: nil, comments: nil, stereo_coding: :auto, predictor: :auto, **codec_options)
          validate_no_codec_options!(codec_options, operation: "FLAC stream_write")
          unless block_given?
            return enum_for(
              __method__,
              io_or_path,
              format: format,
              block_size: block_size,
              block_size_strategy: block_size_strategy,
              compression_level: compression_level,
              comments: comments,
              stereo_coding: stereo_coding,
              predictor: predictor,
              **codec_options
            )
          end

          target_format = validate_encode_format!(format)
          stream_write_options = normalize_stream_write_options(block_size, block_size_strategy, compression_level)
          vorbis_comments = normalize_vorbis_comments(comments)
          normalized_stereo_coding = normalize_stereo_coding!(stereo_coding)
          normalized_predictor = normalize_predictor!(predictor)
          io, close_io = open_output(io_or_path)
          ensure_seekable!(io)
          io.rewind if io.respond_to?(:rewind)
          io.truncate(0) if close_io && io.respond_to?(:truncate)

          header = write_stream_header(io, comments: vorbis_comments)
          total_sample_frames = 0
          next_frame_number = 0
          encode_stats = empty_encode_stats
          header[:md5] = Digest::MD5.new
          pending_samples = []
          pending_offset = 0

          writer = lambda do |chunk|
            raise InvalidParameterError, "stream chunk must be Core::SampleBuffer" unless chunk.is_a?(Core::SampleBuffer)

            buffer = chunk.format == target_format ? chunk : chunk.convert(target_format)
            header.fetch(:md5).update(pcm_bytes_for_md5(buffer.samples, target_format))
            total_sample_frames += buffer.sample_frame_count

            if stream_write_options[:strategy] == :fixed
              pending_samples.concat(buffer.samples)
              fixed_chunk_sample_count = stream_write_options.fetch(:block_size) * target_format.channels

              while (pending_samples.length - pending_offset) >= fixed_chunk_sample_count
                encoded = encode_verbatim_frames(
                  pending_samples.slice(pending_offset, fixed_chunk_sample_count),
                  target_format,
                  start_frame_number: next_frame_number,
                  block_size: stream_write_options.fetch(:block_size),
                  stereo_coding: normalized_stereo_coding,
                  predictor: normalized_predictor
                )
                io.write(encoded.fetch(:bytes))
                next_frame_number = encoded.fetch(:next_frame_number)
                merge_encode_stats!(encode_stats, encoded)
                pending_offset += fixed_chunk_sample_count
              end

              if pending_offset >= fixed_chunk_sample_count * 8
                pending_samples = pending_samples.slice(pending_offset, pending_samples.length - pending_offset) || []
                pending_offset = 0
              end
            elsif stream_write_options[:strategy] == :source_chunk
              encoded = encode_verbatim_frames(
                buffer.samples,
                target_format,
                start_frame_number: next_frame_number,
                block_size: buffer.sample_frame_count,
                stereo_coding: normalized_stereo_coding,
                predictor: normalized_predictor
              )
              io.write(encoded.fetch(:bytes))
              next_frame_number = encoded.fetch(:next_frame_number)
              merge_encode_stats!(encode_stats, encoded)
            else
              encoded = encode_verbatim_frames(
                buffer.samples,
                target_format,
                start_frame_number: next_frame_number,
                block_size: stream_write_options.fetch(:block_size),
                stereo_coding: normalized_stereo_coding,
                predictor: normalized_predictor
              )
              io.write(encoded.fetch(:bytes))
              next_frame_number = encoded.fetch(:next_frame_number)
              merge_encode_stats!(encode_stats, encoded)
            end
          end

          yield writer

          remaining = pending_samples.length - pending_offset
          if remaining.positive?
            encoded = encode_verbatim_frames(
              pending_samples.slice(pending_offset, remaining),
              target_format,
              start_frame_number: next_frame_number,
              block_size: stream_write_options.fetch(:block_size),
              stereo_coding: normalized_stereo_coding,
              predictor: normalized_predictor
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
          seektable = nil
          vorbis_comment = nil
          loop do
            header = read_exact(io, 4, "truncated FLAC metadata block header")
            byte0 = header.getbyte(0)
            last_block = byte0.anybits?(0x80)
            block_type = byte0 & 0x7F
            length = ((header.getbyte(1) << 16) | (header.getbyte(2) << 8) | header.getbyte(3))
            data = read_exact(io, length, "truncated FLAC metadata block")

            case block_type
            when STREAMINFO_BLOCK_TYPE
              streaminfo = parse_streaminfo(data)
            when SEEKTABLE_BLOCK_TYPE
              seektable = parse_seektable(data)
            when VORBIS_COMMENT_BLOCK_TYPE
              vorbis_comment = parse_vorbis_comment(data)
            end
            break if last_block
          end

          raise InvalidFormatError, "STREAMINFO metadata block missing" unless streaminfo

          streaminfo.merge(
            seektable: seektable,
            seekpoints: seektable&.fetch(:points) || [],
            vorbis_comment: vorbis_comment,
            vendor: vorbis_comment&.fetch(:vendor),
            comments: vorbis_comment&.fetch(:comments) || {}
          )
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

        def parse_seektable(data)
          raise InvalidFormatError, "SEEKTABLE block size must be a multiple of 18" unless (data.bytesize % 18).zero?

          points = data.bytes.each_slice(18).map do |bytes|
            block = bytes.pack("C*")
            sample_number = block[0, 8].unpack1("Q>")
            {
              sample_number: sample_number,
              stream_offset: block[8, 8].unpack1("Q>"),
              frame_samples: block[16, 2].unpack1("n"),
              placeholder: sample_number == 0xFFFF_FFFF_FFFF_FFFF
            }
          end
          { points: points }
        end

        def parse_vorbis_comment(data)
          offset = 0
          vendor, offset = read_vorbis_comment_string(data, offset, "vendor")
          comment_count, offset = read_vorbis_comment_uint32(data, offset, "comment count")

          raw = []
          comments = {}
          comment_count.times do
            text, offset = read_vorbis_comment_string(data, offset, "comment")
            raw << text
            key, value = text.split("=", 2)
            comments[key.downcase] = value if key && value
          end

          { vendor: vendor, raw: raw, comments: comments }
        end

        def read_vorbis_comment_uint32(data, offset, label)
          raise InvalidFormatError, "truncated Vorbis Comment #{label}" if offset + 4 > data.bytesize

          [data.byteslice(offset, 4).unpack1("V"), offset + 4]
        end

        def read_vorbis_comment_string(data, offset, label)
          length, offset = read_vorbis_comment_uint32(data, offset, "#{label} length")
          raise InvalidFormatError, "truncated Vorbis Comment #{label}" if offset + length > data.bytesize

          [data.byteslice(offset, length).force_encoding(Encoding::UTF_8), offset + length]
        end

        def encode_verbatim_stream(buffer, format, block_size: DEFAULT_ENCODE_BLOCK_SIZE, comments: nil,
                                   stereo_coding: :auto, predictor: :auto)
          encoded_frames = encode_verbatim_frames(
            buffer.samples,
            format,
            start_frame_number: 0,
            block_size: block_size,
            stereo_coding: stereo_coding,
            predictor: predictor
          )
          md5_hex = pcm_md5_hex(buffer.samples, format)

          streaminfo = build_streaminfo_bytes(
            format: format,
            sample_frame_count: buffer.sample_frame_count,
            stats: encoded_frames,
            md5_hex: md5_hex
          )

          bytes = +"fLaC"
          bytes << metadata_block_header(STREAMINFO_BLOCK_TYPE, STREAMINFO_LENGTH, last: comments.nil?)
          bytes << streaminfo
          if comments
            comment_block = build_vorbis_comment_block(comments)
            bytes << metadata_block_header(VORBIS_COMMENT_BLOCK_TYPE, comment_block.bytesize, last: true)
            bytes << comment_block
          end
          bytes << encoded_frames.fetch(:bytes)
          bytes
        end

        def write_stream_header(io, comments: nil)
          io.write("fLaC")
          io.write(metadata_block_header(STREAMINFO_BLOCK_TYPE, STREAMINFO_LENGTH, last: comments.nil?))
          streaminfo_offset = io.pos
          io.write("\x00" * STREAMINFO_LENGTH)
          if comments
            comment_block = build_vorbis_comment_block(comments)
            io.write(metadata_block_header(VORBIS_COMMENT_BLOCK_TYPE, comment_block.bytesize, last: true))
            io.write(comment_block)
          end
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

        def metadata_block_header(block_type, length, last:)
          [block_type | (last ? 0x80 : 0), (length >> 16) & 0xFF, (length >> 8) & 0xFF, length & 0xFF].pack("C4")
        end

        def build_vorbis_comment_block(comments)
          vendor = "Wavify"
          entries = comments.map { |key, value| "#{key.to_s.upcase}=#{value}" }
          bytes = [vendor.bytesize].pack("V") + vendor + [entries.length].pack("V")
          entries.each do |entry|
            bytes << [entry.bytesize].pack("V")
            bytes << entry
          end
          bytes
        end

        def normalize_vorbis_comments(comments)
          return nil if comments.nil?

          normalized = case comments
                       when Hash
                         comments.transform_keys(&:to_s).transform_values(&:to_s)
                       when Array
                         comments.each_with_object({}) do |entry, result|
                           key, value = entry.to_s.split("=", 2)
                           raise InvalidParameterError, "FLAC comments must be KEY=VALUE strings" unless key && value

                           result[key] = value
                         end
                       else
                         raise InvalidParameterError, "comments must be a Hash or Array"
                       end
          normalized.empty? ? nil : normalized
        end

        def normalize_stereo_coding!(stereo_coding)
          value = stereo_coding.to_sym
          return value if %i[auto independent mid_side].include?(value)

          raise InvalidParameterError, "stereo_coding must be :auto, :independent, or :mid_side"
        rescue NoMethodError
          raise InvalidParameterError, "stereo_coding must be Symbol/String"
        end

        def normalize_predictor!(predictor)
          value = predictor.to_sym
          return value if %i[auto fixed lpc verbatim].include?(value)

          raise InvalidParameterError, "predictor must be :auto, :fixed, :lpc, or :verbatim"
        rescue NoMethodError
          raise InvalidParameterError, "predictor must be Symbol/String"
        end

        def normalize_write_block_size(block_size, compression_level)
          level = normalize_compression_level(compression_level)
          return normalize_encode_block_size(block_size) unless level && block_size == DEFAULT_ENCODE_BLOCK_SIZE

          normalize_encode_block_size(COMPRESSION_BLOCK_SIZES.fetch(level))
        end

        def normalize_compression_level(compression_level)
          return nil if compression_level.nil?

          level = Integer(compression_level)
          return level if level.between?(0, 8)

          raise InvalidParameterError, "compression_level must be in 0..8"
        rescue ArgumentError, TypeError
          raise InvalidParameterError, "compression_level must be an Integer"
        end

        def normalize_stream_write_options(block_size, block_size_strategy, compression_level = nil)
          strategy = block_size_strategy.to_sym
          supported = %i[per_chunk source_chunk fixed]
          unless supported.include?(strategy)
            raise InvalidParameterError, "unsupported FLAC stream_write block_size_strategy: #{block_size_strategy.inspect}"
          end

          {
            strategy: strategy,
            block_size: normalize_write_block_size(block_size, compression_level)
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

        def encode_verbatim_frames(interleaved_samples, format, start_frame_number:, block_size:, stereo_coding: :auto,
                                   predictor: :auto)
          channels = format.channels
          samples_per_frame = channels * normalize_encode_block_size(block_size)
          bytes = +""
          frame_number = start_frame_number
          block_sizes = []
          frame_sizes = []

          interleaved_samples.each_slice(samples_per_frame) do |frame_samples|
            encoded_frame = encode_pcm_frame(
              frame_samples,
              format,
              frame_number: frame_number,
              stereo_coding: stereo_coding,
              predictor: predictor
            )
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

        def encode_pcm_frame(interleaved_samples, format, frame_number:, stereo_coding:, predictor:)
          channels = format.channels
          block_size = interleaved_samples.length / channels
          raise InvalidParameterError, "FLAC frame block size must be positive" if block_size <= 0

          block_size_code, block_size_extra_bits = encode_block_size_descriptor(block_size)
          channel_samples = deinterleave_samples(interleaved_samples, channels)
          candidates = frame_channel_candidates(channel_samples, format, stereo_coding)

          encoded_candidates = candidates.map do |candidate|
            encode_pcm_frame_candidate(
              candidate,
              block_size: block_size,
              block_size_code: block_size_code,
              block_size_extra_bits: block_size_extra_bits,
              frame_number: frame_number,
              predictor: predictor
            )
          end
          selected = if stereo_coding == :auto
                       encoded_candidates.min_by(&:bytesize)
                     else
                       encoded_candidates.fetch(0)
                     end
          selected
        end

        def encode_pcm_frame_candidate(candidate, block_size:, block_size_code:, block_size_extra_bits:,
                                       frame_number:, predictor:)
          header_without_crc8 = build_frame_header_bytes(
            block_size: block_size,
            block_size_code: block_size_code,
            block_size_extra_bits: block_size_extra_bits,
            channel_assignment: candidate.fetch(:channel_assignment),
            frame_number: frame_number
          )
          header_crc8 = flac_crc8(header_without_crc8)

          payload_writer = BitWriter.new
          candidate.fetch(:channel_samples).each_with_index do |channel, channel_index|
            write_best_subframe(payload_writer, channel, candidate.fetch(:sample_sizes).fetch(channel_index), predictor: predictor)
          end
          payload_writer.align_to_byte
          payload_bytes = payload_writer.to_s

          crc16_input = header_without_crc8 + [header_crc8].pack("C") + payload_bytes
          crc16 = flac_crc16(crc16_input)

          crc16_input + [crc16].pack("n")
        end

        def frame_channel_candidates(channel_samples, format, stereo_coding)
          independent = {
            channel_assignment: format.channels - 1,
            channel_samples: channel_samples,
            sample_sizes: Array.new(format.channels, format.bit_depth)
          }
          return [independent] unless format.channels == 2
          return [independent] if stereo_coding == :independent

          left = channel_samples.fetch(0)
          right = channel_samples.fetch(1)
          side = left.zip(right).map { |l, r| l - r }
          mid = left.zip(right).map { |l, r| (l + r) >> 1 }
          mid_side = {
            channel_assignment: 10,
            channel_samples: [mid, side],
            sample_sizes: [format.bit_depth, format.bit_depth + 1]
          }
          stereo_coding == :mid_side ? [mid_side] : [independent, mid_side]
        end

        def write_best_subframe(writer, channel_samples, sample_size, predictor:)
          selection = select_subframe_encoding(channel_samples, sample_size, predictor: predictor)

          if selection[:kind] == :fixed
            write_fixed_subframe(
              writer,
              channel_samples,
              sample_size,
              selection: selection
            )
            return
          end

          if selection[:kind] == :lpc
            write_lpc_subframe(
              writer,
              channel_samples,
              sample_size,
              selection: selection
            )
            return
          end

          write_verbatim_subframe(writer, channel_samples, sample_size)
        end

        def select_subframe_encoding(channel_samples, sample_size, predictor:)
          best = {
            kind: :verbatim,
            bit_length: verbatim_subframe_bit_length(channel_samples.length, sample_size)
          }
          return best if predictor == :verbatim

          if %i[auto fixed].include?(predictor)
            max_predictor_order = [4, channel_samples.length - 1].min
            (0..max_predictor_order).each do |predictor_order|
              candidate = build_fixed_subframe_encoding(channel_samples, sample_size, predictor_order)
              next unless candidate
              next unless candidate.fetch(:bit_length) < best.fetch(:bit_length)

              best = candidate
            end
          end

          if %i[auto lpc].include?(predictor)
            (1..[8, channel_samples.length - 1].min).each do |order|
              candidate = build_lpc_subframe_encoding(channel_samples, sample_size, order)
              next unless candidate
              next unless candidate.fetch(:bit_length) < best.fetch(:bit_length)

              best = candidate
            end
          end

          best
        end

        def verbatim_subframe_bit_length(sample_count, sample_size)
          8 + (sample_count * sample_size)
        end

        def build_fixed_subframe_encoding(channel_samples, sample_size, predictor_order)
          residuals = fixed_subframe_residuals(channel_samples, predictor_order)
          residual_encoding = choose_residual_encoding(
            residuals,
            block_size: channel_samples.length,
            predictor_order: predictor_order
          )
          return nil unless residual_encoding

          {
            kind: :fixed,
            predictor_order: predictor_order,
            residuals: residuals,
            residual_encoding: residual_encoding,
            bit_length: 8 + (predictor_order * sample_size) + residual_encoding.fetch(:bit_length)
          }
        end

        def build_lpc_subframe_encoding(channel_samples, sample_size, predictor_order)
          return nil if predictor_order >= channel_samples.length

          coefficient_data = quantized_lpc_coefficients(channel_samples, predictor_order, sample_size)
          return nil unless coefficient_data

          coefficients = coefficient_data.fetch(:coefficients)
          qlp_shift = coefficient_data.fetch(:qlp_shift)
          coefficient_precision = coefficient_data.fetch(:precision)
          residuals = lpc_subframe_residuals(channel_samples, coefficients, qlp_shift)
          residual_encoding = choose_residual_encoding(
            residuals,
            block_size: channel_samples.length,
            predictor_order: predictor_order
          )
          return nil unless residual_encoding

          {
            kind: :lpc,
            predictor_order: predictor_order,
            coefficients: coefficients,
            coefficient_precision: coefficient_precision,
            qlp_shift: qlp_shift,
            residuals: residuals,
            residual_encoding: residual_encoding,
            bit_length: 8 + (predictor_order * sample_size) + 4 + 5 +
              (predictor_order * coefficient_precision) + residual_encoding.fetch(:bit_length)
          }
        end

        def quantized_lpc_coefficients(samples, predictor_order, sample_size)
          coefficients = levinson_durbin_coefficients(samples, predictor_order)
          return nil unless coefficients

          precision = [sample_size, 15].min
          maximum = coefficients.map(&:abs).max
          return nil unless maximum&.positive?

          max_integer = (1 << (precision - 1)) - 1
          qlp_shift = Math.log2(max_integer / maximum).floor.clamp(-16, 15)
          quantized = coefficients.map { |coefficient| (coefficient * (2.0**qlp_shift)).round }
          return nil unless quantized.all? { |coefficient| signed_bit_width(coefficient) <= precision }

          { coefficients: quantized, precision: precision, qlp_shift: qlp_shift }
        end

        def levinson_durbin_coefficients(samples, predictor_order)
          return nil if samples.length <= predictor_order

          autocorrelation = Array.new(predictor_order + 1) do |lag|
            (lag...samples.length).sum { |index| samples.fetch(index).to_f * samples.fetch(index - lag) }
          end
          error = autocorrelation.fetch(0)
          return nil unless error.positive?

          coefficients = []
          predictor_order.times do |index|
            correction = index.times.sum do |coefficient_index|
              coefficients.fetch(coefficient_index) * autocorrelation.fetch(index - coefficient_index)
            end
            reflection = (autocorrelation.fetch(index + 1) - correction) / error
            return nil unless reflection.finite? && reflection.abs < 1.0

            previous = coefficients.dup
            index.times do |coefficient_index|
              coefficients[coefficient_index] = previous.fetch(coefficient_index) -
                                                (reflection * previous.fetch(index - coefficient_index - 1))
            end
            coefficients[index] = reflection
            error *= 1.0 - (reflection * reflection)
            return nil unless error.positive?
          end
          coefficients
        end

        def lpc_subframe_residuals(samples, coefficients, qlp_shift)
          predictor_order = coefficients.length
          samples.drop(predictor_order).each_with_index.map do |sample, index|
            history_index = predictor_order + index
            sum = coefficients.each_with_index.sum do |coefficient, coefficient_index|
              coefficient * samples.fetch(history_index - coefficient_index - 1)
            end
            predicted = qlp_shift.negative? ? (sum << -qlp_shift) : (sum >> qlp_shift)
            sample - predicted
          end
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

        def choose_residual_encoding(residuals, block_size:, predictor_order:)
          max_partition_order = [Math.log2(block_size).floor, 6].min
          candidates = (0..max_partition_order).filter_map do |partition_order|
            partition_count = 1 << partition_order
            next unless (block_size % partition_count).zero?

            partition_size = block_size / partition_count
            next if partition_size < predictor_order

            partitions = residual_partitions(
              residuals,
              partition_count: partition_count,
              partition_size: partition_size,
              predictor_order: predictor_order
            )
            next unless partitions

            encodings = partitions.map { |partition| choose_rice_partition_encoding(partition) }
            {
              kind: :partitioned,
              partition_order: partition_order,
              partitions: partitions.zip(encodings),
              bit_length: 6 + encodings.sum { |encoding| encoding.fetch(:bit_length) }
            }
          end
          candidates.min_by { |candidate| candidate.fetch(:bit_length) }
        end

        def residual_partitions(residuals, partition_count:, partition_size:, predictor_order:)
          offset = 0
          partitions = Array.new(partition_count) do |partition_index|
            length = partition_size - (partition_index.zero? ? predictor_order : 0)
            partition = residuals.slice(offset, length)
            return nil unless partition&.length == length

            offset += length
            partition
          end
          offset == residuals.length ? partitions : nil
        end

        def choose_rice_partition_encoding(residuals)
          rice_candidates = (0..14).map do |parameter|
            { kind: :rice, parameter: parameter, bit_length: 4 + rice_data_bit_length(residuals, parameter) }
          end
          escape = escape_residual_encoding(residuals)
          rice_candidates << escape if escape
          rice_candidates.min_by { |candidate| candidate.fetch(:bit_length) }
        end

        def rice_data_bit_length(residuals, parameter)
          residuals.sum do |residual|
            unsigned = residual >= 0 ? (residual << 1) : ((-residual << 1) - 1)
            quotient = unsigned >> parameter
            quotient + 1 + parameter
          end
        end

        def escape_residual_encoding(residuals)
          raw_bits = residuals.map { |residual| signed_bit_width(residual) }.max.to_i
          return nil if raw_bits > 31

          {
            kind: :escape,
            raw_bits: raw_bits,
            bit_length: 4 + 5 + (residuals.length * raw_bits)
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

          writer.write_bits(0, 1) # padding bit
          writer.write_bits(8 + predictor_order, 6)
          writer.write_bits(0, 1) # no wasted bits

          channel_samples.first(predictor_order).each { |sample| writer.write_signed_bits(sample, sample_size) }
          write_residuals(writer, residual_encoding)
        end

        def write_residuals(writer, residual_encoding)
          writer.write_bits(0, 2) # Rice coding method family
          writer.write_bits(residual_encoding.fetch(:partition_order), 4)
          residual_encoding.fetch(:partitions).each do |residuals, partition|
            if partition[:kind] == :rice
              writer.write_bits(partition.fetch(:parameter), 4)
              residuals.each { |residual| writer.write_rice_signed(residual, partition.fetch(:parameter)) }
              next
            end

            writer.write_bits(0xF, 4) # escape code
            raw_bits = partition.fetch(:raw_bits)
            writer.write_bits(raw_bits, 5)
            residuals.each { |residual| writer.write_signed_bits(residual, raw_bits) } if raw_bits.positive?
          end
        end

        def build_frame_header_bytes(block_size:, block_size_code:, block_size_extra_bits:, channel_assignment:, frame_number:)
          writer = BitWriter.new
          writer.write_bits(FLAC_SYNC_CODE, 14)
          writer.write_bits(0, 1) # reserved
          writer.write_bits(0, 1) # fixed-blocksize stream
          writer.write_bits(block_size_code, 4)
          writer.write_bits(0, 4) # sample rate from STREAMINFO
          writer.write_bits(channel_assignment, 4)
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

        def write_lpc_subframe(writer, channel_samples, sample_size, selection:)
          predictor_order = selection.fetch(:predictor_order)
          writer.write_bits(0, 1) # padding bit
          writer.write_bits(32 + predictor_order - 1, 6)
          writer.write_bits(0, 1) # no wasted bits

          channel_samples.first(predictor_order).each { |sample| writer.write_signed_bits(sample, sample_size) }
          writer.write_bits(selection.fetch(:coefficient_precision) - 1, 4)
          writer.write_signed_bits(selection.fetch(:qlp_shift), 5)
          selection.fetch(:coefficients).each do |coefficient|
            writer.write_signed_bits(coefficient, selection.fetch(:coefficient_precision))
          end
          write_residuals(writer, selection.fetch(:residual_encoding))
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
          md5 = decoded_pcm_md5(metadata)

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

            md5&.update(pcm_bytes_for_md5(frame_samples, format))
            yield frame_samples unless frame_samples.empty?
          end

          if bounded_total && remaining_frames.positive?
            raise InvalidFormatError, "decoded FLAC samples are shorter than STREAMINFO total sample count"
          end

          verify_decoded_pcm_md5!(md5, metadata[:md5])
        end

        def decode_frame(io, metadata)
          frame_start = io.pos
          bit_reader = BitReader.new(io)
          frame_header = parse_frame_header(bit_reader, metadata, io: io, frame_start: frame_start)
          channel_samples = decode_subframes(bit_reader, frame_header)
          channel_samples = restore_channel_assignment(channel_samples, frame_header)
          bit_reader.align_to_byte
          crc_offset = io.pos
          expected_crc16 = bit_reader.read_bits(16)
          actual_crc16 = flac_crc16(io_bytes(io, frame_start, crc_offset))
          raise InvalidFormatError, "FLAC frame CRC-16 mismatch" unless expected_crc16 == actual_crc16

          interleave_channels(channel_samples, frame_header.fetch(:block_size), frame_header.fetch(:channels))
        end

        def parse_frame_header(bit_reader, metadata, io:, frame_start:)
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
          crc_offset = io.pos
          expected_crc8 = bit_reader.read_bits(8)
          actual_crc8 = flac_crc8(io_bytes(io, frame_start, crc_offset))
          raise InvalidFormatError, "FLAC frame header CRC-8 mismatch" unless expected_crc8 == actual_crc8

          channels = decode_channel_count(channel_assignment, metadata.fetch(:format).channels)

          {
            block_size: block_size,
            sample_rate: sample_rate,
            sample_size: sample_size,
            channels: channels,
            channel_assignment: channel_assignment
          }
        end

        def io_bytes(io, start_offset, end_offset)
          current_offset = io.pos
          io.seek(start_offset, IO::SEEK_SET)
          bytes = read_exact(io, end_offset - start_offset, "truncated FLAC checksum input")
          io.seek(current_offset, IO::SEEK_SET)
          bytes
        end

        def decoded_pcm_md5(metadata)
          expected = metadata[:md5]
          return if expected.nil? || expected == ("0" * 32)

          Digest::MD5.new
        end

        def verify_decoded_pcm_md5!(md5, expected)
          return unless md5
          return if md5.hexdigest == expected

          raise InvalidFormatError, "FLAC STREAMINFO MD5 mismatch"
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
