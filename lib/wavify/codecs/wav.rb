# frozen_string_literal: true

module Wavify
  module Codecs
    # WAV codec with PCM, float, and WAVE_FORMAT_EXTENSIBLE support.
    class Wav < Base
      # Recognized filename extensions.
      EXTENSIONS = %w[.wav .wave].freeze
      WAV_FORMAT_PCM = 0x0001 # :nodoc:
      WAV_FORMAT_FLOAT = 0x0003 # :nodoc:
      WAV_FORMAT_EXTENSIBLE = 0xFFFE # :nodoc:

      GUID_TAIL = [0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71].pack("C*").freeze # :nodoc:
      PCM_SUBFORMAT_GUID = ([WAV_FORMAT_PCM, 0x0000, 0x0010].pack("V v v") + GUID_TAIL).freeze # :nodoc:
      FLOAT_SUBFORMAT_GUID = ([WAV_FORMAT_FLOAT, 0x0000, 0x0010].pack("V v v") + GUID_TAIL).freeze # :nodoc:

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
          header&.start_with?("RIFF") && header[8, 4] == "WAVE"
        ensure
          io.close if close_io && io
        end

        # Reads a WAV file/IO into a sample buffer.
        #
        # @param io_or_path [String, IO]
        # @param format [Wavify::Core::Format, nil] optional output conversion
        # @return [Wavify::Core::SampleBuffer]
        def read(io_or_path, format: nil)
          io, close_io = open_input(io_or_path)
          ensure_seekable!(io)

          info = parse_chunk_directory(io)
          source_format = info.fetch(:format)
          samples = read_data_chunk(io, info, source_format)
          buffer = Core::SampleBuffer.new(samples, source_format)
          format ? buffer.convert(format) : buffer
        ensure
          io.close if close_io && io
        end

        # Writes a sample buffer as WAV.
        #
        # @param io_or_path [String, IO]
        # @param sample_buffer [Wavify::Core::SampleBuffer]
        # @param format [Wavify::Core::Format, nil]
        # @return [String, IO]
        def write(io_or_path, sample_buffer, format: nil)
          raise InvalidParameterError, "sample_buffer must be Core::SampleBuffer" unless sample_buffer.is_a?(Core::SampleBuffer)

          target_format = format || sample_buffer.format
          raise InvalidParameterError, "format must be Core::Format" unless target_format.is_a?(Core::Format)

          buffer = sample_buffer.format == target_format ? sample_buffer : sample_buffer.convert(target_format)
          stream_write(io_or_path, format: target_format) do |writer|
            writer.call(buffer)
          end
        end

        # Streams WAV data chunks as sample buffers.
        #
        # @param io_or_path [String, IO]
        # @param chunk_size [Integer]
        # @return [Enumerator]
        def stream_read(io_or_path, chunk_size: 4096)
          return enum_for(__method__, io_or_path, chunk_size: chunk_size) unless block_given?
          raise InvalidParameterError, "chunk_size must be a positive Integer" unless chunk_size.is_a?(Integer) && chunk_size.positive?

          io, close_io = open_input(io_or_path)
          ensure_seekable!(io)

          info = parse_chunk_directory(io)
          format = info.fetch(:format)
          bytes_per_frame = format.block_align
          remaining = info.fetch(:data_size)

          io.seek(info.fetch(:data_offset), IO::SEEK_SET)
          while remaining.positive?
            to_read = [remaining, chunk_size * bytes_per_frame].min
            chunk_data = read_exact(io, to_read, "truncated data chunk")
            samples = decode_samples(chunk_data, format)
            yield Core::SampleBuffer.new(samples, format)
            remaining -= to_read
          end
        ensure
          io.close if close_io && io
        end

        # Streams WAV encoding and finalizes the RIFF header on completion.
        #
        # @param io_or_path [String, IO]
        # @param format [Wavify::Core::Format]
        # @return [Enumerator, String, IO]
        def stream_write(io_or_path, format:)
          return enum_for(__method__, io_or_path, format: format) unless block_given?
          raise InvalidParameterError, "format must be Core::Format" unless format.is_a?(Core::Format)

          io, close_io = open_output(io_or_path)
          ensure_seekable!(io)
          io.rewind if io.respond_to?(:rewind)
          io.truncate(0) if io.respond_to?(:truncate)

          header = write_stream_header(io, format)
          total_data_bytes = 0
          total_sample_frames = 0

          writer = lambda do |chunk|
            raise InvalidParameterError, "stream chunk must be Core::SampleBuffer" unless chunk.is_a?(Core::SampleBuffer)

            buffer = chunk.format == format ? chunk : chunk.convert(format)
            encoded = encode_samples(buffer.samples, format)
            io.write(encoded)
            total_data_bytes += encoded.bytesize
            total_sample_frames += buffer.sample_frame_count
          end

          yield writer
          io.write("\x00") if total_data_bytes.odd?
          finalize_stream_header(io, header, total_data_bytes, total_sample_frames)
          io.flush if io.respond_to?(:flush)
          io.rewind if io.respond_to?(:rewind)
          io_or_path
        ensure
          io.close if close_io && io
        end

        # Reads WAV metadata without fully decoding samples.
        #
        # @param io_or_path [String, IO]
        # @return [Hash]
        def metadata(io_or_path)
          io, close_io = open_input(io_or_path)
          ensure_seekable!(io)

          info = parse_chunk_directory(io)
          format = info.fetch(:format)
          sample_frame_count = info.fetch(:sample_frame_count)

          {
            format: format,
            sample_frame_count: sample_frame_count,
            duration: Core::Duration.from_samples(sample_frame_count, format.sample_rate),
            fact_sample_length: info[:fact_sample_length],
            smpl: info[:smpl]
          }
        ensure
          io.close if close_io && io
        end

        private

        def write_stream_header(io, format)
          io.write("RIFF")
          riff_size_offset = io.pos
          io.write([0].pack("V"))
          io.write("WAVE")

          fmt_chunk = build_fmt_chunk(format)
          write_chunk(io, "fmt ", fmt_chunk)

          fact_sample_offset = nil
          if format.sample_format != :pcm
            io.write("fact")
            io.write([4].pack("V"))
            fact_sample_offset = io.pos
            io.write([0].pack("V"))
          end

          io.write("data")
          data_size_offset = io.pos
          io.write([0].pack("V"))

          {
            riff_size_offset: riff_size_offset,
            data_size_offset: data_size_offset,
            fact_sample_offset: fact_sample_offset
          }
        end

        def finalize_stream_header(io, header, total_data_bytes, total_sample_frames)
          file_end = io.pos

          io.seek(header.fetch(:data_size_offset), IO::SEEK_SET)
          io.write([total_data_bytes].pack("V"))

          fact_sample_offset = header[:fact_sample_offset]
          if fact_sample_offset
            io.seek(fact_sample_offset, IO::SEEK_SET)
            io.write([total_sample_frames].pack("V"))
          end

          io.seek(header.fetch(:riff_size_offset), IO::SEEK_SET)
          io.write([file_end - 8].pack("V"))
          io.seek(file_end, IO::SEEK_SET)
        end

        def parse_chunk_directory(io)
          io.rewind
          header = read_exact(io, 12, "missing RIFF/WAVE header")
          raise InvalidFormatError, "invalid WAV header" unless header.start_with?("RIFF") && header[8, 4] == "WAVE"

          info = {
            format: nil,
            data_offset: nil,
            data_size: nil,
            sample_frame_count: nil,
            fact_sample_length: nil,
            smpl: nil
          }

          until io.eof?
            chunk_header = io.read(8)
            break if chunk_header.nil?
            raise InvalidFormatError, "truncated chunk header" unless chunk_header.bytesize == 8

            chunk_id = chunk_header[0, 4]
            chunk_size = chunk_header[4, 4].unpack1("V")

            case chunk_id
            when "fmt "
              chunk_data = read_exact(io, chunk_size, "truncated fmt chunk")
              info[:format] = parse_fmt_chunk(chunk_data)
            when "data"
              info[:data_offset] = io.pos
              info[:data_size] = chunk_size
              skip_bytes(io, chunk_size)
            when "fact"
              chunk_data = read_exact(io, chunk_size, "truncated fact chunk")
              info[:fact_sample_length] = chunk_data.unpack1("V") if chunk_data.bytesize >= 4
            when "smpl"
              chunk_data = read_exact(io, chunk_size, "truncated smpl chunk")
              info[:smpl] = parse_smpl_chunk(chunk_data)
            else
              skip_bytes(io, chunk_size)
            end

            skip_padding_byte(io, chunk_size)
          end

          raise InvalidFormatError, "fmt chunk missing" unless info[:format]
          raise InvalidFormatError, "data chunk missing" unless info[:data_offset] && info[:data_size]

          validate_data_chunk!(io, info)
          info[:sample_frame_count] = info[:data_size] / info[:format].block_align
          info
        end

        def validate_data_chunk!(io, info)
          format = info.fetch(:format)
          data_size = info.fetch(:data_size)
          data_offset = info.fetch(:data_offset)
          block_align = format.block_align

          raise InvalidFormatError, "data chunk size is not aligned to frame size" unless (data_size % block_align).zero?

          return unless io.respond_to?(:size)
          return unless data_offset + data_size > io.size

          raise InvalidFormatError, "data chunk exceeds file size"
        end

        def read_data_chunk(io, info, format)
          io.seek(info.fetch(:data_offset), IO::SEEK_SET)
          data = read_exact(io, info.fetch(:data_size), "truncated data chunk")
          decode_samples(data, format)
        end

        def parse_fmt_chunk(chunk)
          raise InvalidFormatError, "fmt chunk is too small" if chunk.bytesize < 16

          audio_format, channels, sample_rate, byte_rate, block_align, bit_depth = chunk.unpack("v v V V v v")

          if audio_format == WAV_FORMAT_EXTENSIBLE
            raise InvalidFormatError, "fmt extensible chunk is too small" if chunk.bytesize < 40

            extension_size = chunk[16, 2].unpack1("v")
            raise InvalidFormatError, "invalid extensible fmt chunk size" if extension_size < 22 || chunk.bytesize < (18 + extension_size)

            valid_bits = chunk[18, 2].unpack1("v")
            sub_format_guid = chunk[24, 16]
            audio_format = sub_format_guid.unpack1("v")
            bit_depth = valid_bits if valid_bits.positive?
          end

          sample_format = case audio_format
                          when WAV_FORMAT_PCM then :pcm
                          when WAV_FORMAT_FLOAT then :float
                          else
                            raise UnsupportedFormatError, "unsupported WAV format code: #{audio_format}"
                          end

          format = Core::Format.new(
            channels: channels,
            sample_rate: sample_rate,
            bit_depth: bit_depth,
            sample_format: sample_format
          )

          expected_block_align = format.block_align
          expected_byte_rate = format.byte_rate
          unless block_align == expected_block_align && byte_rate == expected_byte_rate
            raise InvalidFormatError, "fmt chunk has inconsistent byte_rate/block_align"
          end

          format
        end

        def parse_smpl_chunk(chunk)
          return nil if chunk.bytesize < 36

          manufacturer, product, sample_period, midi_unity_note, midi_pitch_fraction,
            smpte_format, smpte_offset, loop_count, sampler_data = chunk.unpack("V9")

          loops = []
          offset = 36
          loop_count.times do
            break if offset + 24 > chunk.bytesize

            identifier, loop_type, start_frame, end_frame, fraction, play_count = chunk.byteslice(offset, 24).unpack("V6")
            loops << {
              identifier: identifier,
              type: loop_type,
              start_frame: start_frame,
              end_frame: end_frame,
              fraction: fraction,
              play_count: play_count
            }
            offset += 24
          end

          {
            manufacturer: manufacturer,
            product: product,
            sample_period: sample_period,
            midi_unity_note: midi_unity_note,
            midi_pitch_fraction: midi_pitch_fraction,
            smpte_format: smpte_format,
            smpte_offset: smpte_offset,
            sampler_data: sampler_data,
            loop_count: loop_count,
            loops: loops
          }
        end

        def decode_samples(data_chunk, format)
          if format.sample_format == :float
            return data_chunk.unpack("e*") if format.bit_depth == 32
            return data_chunk.unpack("E*") if format.bit_depth == 64
          elsif format.sample_format == :pcm
            return data_chunk.unpack("C*").map { |byte| byte - 128 } if format.bit_depth == 8
            return data_chunk.unpack("s<*") if format.bit_depth == 16
            return decode_pcm24(data_chunk) if format.bit_depth == 24
            return data_chunk.unpack("l<*") if format.bit_depth == 32
          end

          raise UnsupportedFormatError, "unsupported WAV bit depth: #{format.bit_depth}"
        end

        def decode_pcm24(data)
          bytes = data.unpack("C*")
          bytes.each_slice(3).map do |b0, b1, b2|
            value = b0 | (b1 << 8) | (b2 << 16)
            value -= 0x1000000 if value.anybits?(0x800000)
            value
          end
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

          raise UnsupportedFormatError, "cannot encode WAV format: #{format.inspect}"
        end

        def encode_pcm24(samples)
          bytes = samples.flat_map do |sample|
            value = sample
            value += 0x1000000 if value.negative?
            [value & 0xFF, (value >> 8) & 0xFF, (value >> 16) & 0xFF]
          end
          bytes.pack("C*")
        end

        def build_fmt_chunk(format)
          return build_standard_fmt_chunk(format) unless use_extensible_format?(format)

          base_format_code = format.sample_format == :pcm ? WAV_FORMAT_PCM : WAV_FORMAT_FLOAT
          channel_mask = channel_mask_for(format.channels)
          sub_format_guid = base_format_code == WAV_FORMAT_PCM ? PCM_SUBFORMAT_GUID : FLOAT_SUBFORMAT_GUID

          [WAV_FORMAT_EXTENSIBLE, format.channels, format.sample_rate, format.byte_rate, format.block_align, format.bit_depth,
           22, format.bit_depth, channel_mask].pack("v v V V v v v v V") + sub_format_guid
        end

        def build_standard_fmt_chunk(format)
          format_code = format.sample_format == :pcm ? WAV_FORMAT_PCM : WAV_FORMAT_FLOAT
          [format_code, format.channels, format.sample_rate, format.byte_rate, format.block_align, format.bit_depth]
            .pack("v v V V v v")
        end

        def use_extensible_format?(format)
          format.channels > 2 || format.bit_depth > 16
        end

        def channel_mask_for(channels)
          return 0 if channels <= 0
          return 0x4 if channels == 1
          return 0x3 if channels == 2
          return 0x7 if channels == 3
          return 0x33 if channels == 4
          return 0x37 if channels == 5
          return 0x3F if channels == 6
          return 0x13F if channels == 7
          return 0x63F if channels == 8

          ((1 << [channels, 32].min) - 1) & 0xFFFF_FFFF
        end

        def write_chunk(io, chunk_id, chunk_data)
          io.write(chunk_id)
          io.write([chunk_data.bytesize].pack("V"))
          io.write(chunk_data)
          io.write("\x00") if chunk_data.bytesize.odd?
        end

        def skip_padding_byte(io, chunk_size)
          return unless chunk_size.odd?

          padding = io.read(1)
          raise InvalidFormatError, "missing padding byte after odd-sized chunk" unless padding && padding.bytesize == 1
        end

      end
    end
  end
end
