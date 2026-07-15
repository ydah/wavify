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
        def read(io_or_path, format: nil, endianness: :little, signed: nil, float_domain: :normalized, **codec_options)
          validate_no_codec_options!(codec_options, operation: "raw read")
          target_format = validate_format!(format)
          encoding = normalize_raw_encoding(
            target_format,
            endianness: endianness,
            signed: signed,
            float_domain: float_domain
          )
          io, close_io = open_input(io_or_path)
          data = read_to_end(io)
          validate_frame_alignment!(data.bytesize, target_format)
          samples = decode_samples(data, target_format, **encoding)
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
        def write(io_or_path, sample_buffer, format:, endianness: :little, signed: nil, float_domain: :normalized,
                  **codec_options)
          validate_no_codec_options!(codec_options, operation: "raw write")
          raise InvalidParameterError, "sample_buffer must be Core::SampleBuffer" unless sample_buffer.is_a?(Core::SampleBuffer)

          target_format = validate_format!(format)
          encoding = normalize_raw_encoding(
            target_format,
            endianness: endianness,
            signed: signed,
            float_domain: float_domain
          )
          buffer = sample_buffer.format == target_format ? sample_buffer : sample_buffer.convert(target_format)

          io, close_io = open_output(io_or_path)
          prepare_output!(io, owned: close_io)
          write_all(io, encode_samples(buffer.samples, target_format, **encoding))
          finalize_output!(io, owned: close_io)
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
        def stream_read(io_or_path, format:, chunk_size: 4096, endianness: :little, signed: nil,
                        float_domain: :normalized, **codec_options)
          validate_no_codec_options!(codec_options, operation: "raw stream_read")
          unless block_given?
            return enum_for(
              __method__,
              io_or_path,
              format: format,
              chunk_size: chunk_size,
              endianness: endianness,
              signed: signed,
              float_domain: float_domain,
              **codec_options
            )
          end

          target_format = validate_format!(format)
          encoding = normalize_raw_encoding(
            target_format,
            endianness: endianness,
            signed: signed,
            float_domain: float_domain
          )
          io, close_io = open_input(io_or_path)
          bytes_per_frame = target_format.block_align
          raw_chunk_size = chunk_size * bytes_per_frame
          pending = +"".b

          loop do
            chunk = io.read(raw_chunk_size)
            break if chunk.nil? || chunk.empty?

            pending << chunk
            usable_bytes = pending.bytesize - (pending.bytesize % bytes_per_frame)
            next if usable_bytes.zero?

            frame_data = pending.byteslice(0, usable_bytes)
            pending = pending.byteslice(usable_bytes, pending.bytesize - usable_bytes) || +"".b
            samples = decode_samples(frame_data, target_format, **encoding)
            yield Core::SampleBuffer.new(samples, target_format)
          end
          raise InvalidFormatError, "raw data ends with a partial sample frame" unless pending.empty?
        ensure
          io.close if close_io && io
        end

        # Streams raw audio encoding via a yielded chunk writer.
        #
        # @param io_or_path [String, IO]
        # @param format [Wavify::Core::Format]
        # @return [Enumerator, String, IO]
        def stream_write(io_or_path, format:, endianness: :little, signed: nil, float_domain: :normalized,
                         **codec_options)
          validate_no_codec_options!(codec_options, operation: "raw stream_write")
          unless block_given?
            return enum_for(
              __method__,
              io_or_path,
              format: format,
              endianness: endianness,
              signed: signed,
              float_domain: float_domain,
              **codec_options
            )
          end

          target_format = validate_format!(format)
          encoding = normalize_raw_encoding(
            target_format,
            endianness: endianness,
            signed: signed,
            float_domain: float_domain
          )
          io, close_io = open_output(io_or_path)
          prepare_output!(io, owned: close_io)

          writer = lambda do |sample_buffer|
            raise InvalidParameterError, "stream chunk must be Core::SampleBuffer" unless sample_buffer.is_a?(Core::SampleBuffer)

            buffer = sample_buffer.format == target_format ? sample_buffer : sample_buffer.convert(target_format)
            write_all(io, encode_samples(buffer.samples, target_format, **encoding))
          end

          yield writer
          finalize_output!(io, owned: close_io)
          io_or_path
        ensure
          io.close if close_io && io
        end

        # Reads raw audio metadata using byte size and explicit format.
        #
        # @param io_or_path [String, IO]
        # @param format [Wavify::Core::Format]
        # @return [Hash]
        def metadata(io_or_path, format:, endianness: :little, signed: nil, float_domain: :normalized, **codec_options)
          validate_no_codec_options!(codec_options, operation: "raw metadata")
          target_format = validate_format!(format)
          normalize_raw_encoding(target_format, endianness: endianness, signed: signed, float_domain: float_domain)
          io, close_io = open_input(io_or_path)
          byte_size = byte_size_without_consuming!(io)
          validate_frame_alignment!(byte_size, target_format)
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

        def validate_frame_alignment!(byte_size, format)
          return if (byte_size % format.block_align).zero?

          raise InvalidFormatError, "raw data size does not align with format frame size"
        end

        def byte_size_without_consuming!(io)
          return io.size - io.pos if io.respond_to?(:size) && io.respond_to?(:pos)
          return io.size if io.respond_to?(:size)

          if io.respond_to?(:pos) && io.respond_to?(:seek)
            original_position = io.pos
            io.seek(0, IO::SEEK_END)
            byte_size = io.pos - original_position
            io.seek(original_position, IO::SEEK_SET)
            return byte_size
          end

          raise InvalidParameterError, "raw metadata requires IO with size or seek support"
        end

        def decode_samples(data, format, endianness:, signed:, float_domain:)
          if format.sample_format == :float
            directive = if format.bit_depth == 32
                          endianness == :little ? "e*" : "g*"
                        else
                          endianness == :little ? "E*" : "G*"
                        end
            samples = data.unpack(directive)
            validate_normalized_float_samples!(samples) if float_domain == :normalized
            return samples
          elsif format.sample_format == :pcm
            return decode_pcm8(data, signed: signed) if format.bit_depth == 8
            return decode_pcm_word(data, bits: 16, endianness: endianness, signed: signed) if format.bit_depth == 16
            return decode_pcm24(data, endianness: endianness, signed: signed) if format.bit_depth == 24
            return decode_pcm_word(data, bits: 32, endianness: endianness, signed: signed) if format.bit_depth == 32
          end

          raise UnsupportedFormatError, "unsupported raw format: #{format.sample_format}/#{format.bit_depth}"
        end

        def encode_samples(samples, format, endianness:, signed:, float_domain:)
          if format.sample_format == :float
            values = if float_domain == :normalized
                       samples.map { |sample| sample.to_f.clamp(-1.0, 1.0) }
                     else
                       samples.map(&:to_f)
                     end
            directive = if format.bit_depth == 32
                          endianness == :little ? "e*" : "g*"
                        else
                          endianness == :little ? "E*" : "G*"
                        end
            return values.pack(directive)
          elsif format.sample_format == :pcm
            min = -(2**(format.bit_depth - 1))
            max = (2**(format.bit_depth - 1)) - 1
            ints = samples.map { |sample| sample.to_i.clamp(min, max) }
            return encode_pcm8(ints, signed: signed) if format.bit_depth == 8
            return encode_pcm_word(ints, bits: 16, endianness: endianness, signed: signed) if format.bit_depth == 16
            return encode_pcm24(ints, endianness: endianness, signed: signed) if format.bit_depth == 24
            return encode_pcm_word(ints, bits: 32, endianness: endianness, signed: signed) if format.bit_depth == 32
          end

          raise UnsupportedFormatError, "unsupported raw format: #{format.sample_format}/#{format.bit_depth}"
        end

        def decode_pcm8(data, signed:)
          return data.unpack("c*") if signed

          data.each_byte.map { |byte| byte - 128 }
        end

        def encode_pcm8(samples, signed:)
          return samples.pack("c*") if signed

          samples.map { |sample| sample + 128 }.pack("C*")
        end

        def decode_pcm_word(data, bits:, endianness:, signed:)
          directive = pcm_word_directive(bits, endianness, signed)
          values = data.unpack("#{directive}*")
          return values if signed

          midpoint = 2**(bits - 1)
          values.map! { |value| value - midpoint }
        end

        def encode_pcm_word(samples, bits:, endianness:, signed:)
          directive = pcm_word_directive(bits, endianness, signed)
          values = if signed
                     samples
                   else
                     midpoint = 2**(bits - 1)
                     samples.map { |sample| sample + midpoint }
                   end
          values.pack("#{directive}*")
        end

        def pcm_word_directive(bits, endianness, signed)
          base = if bits == 16
                   signed ? "s" : "S"
                 else
                   signed ? "l" : "L"
                 end
          "#{base}#{endianness == :little ? '<' : '>'}"
        end

        def decode_pcm24(data, endianness:, signed:)
          midpoint = 0x800000
          samples = Array.new(data.bytesize / 3)
          samples.length.times do |index|
            offset = index * 3
            first = data.getbyte(offset)
            middle = data.getbyte(offset + 1)
            last = data.getbyte(offset + 2)
            value = if endianness == :little
                      first | (middle << 8) | (last << 16)
                    else
                      last | (middle << 8) | (first << 16)
                    end
            samples[index] = signed ? (value.anybits?(midpoint) ? value - 0x1000000 : value) : value - midpoint
          end
          samples
        end

        def encode_pcm24(samples, endianness:, signed:)
          bytes = String.new(capacity: samples.length * 3, encoding: Encoding::BINARY)
          samples.each do |sample|
            value = signed ? (sample.negative? ? sample + 0x1000000 : sample) : sample + 0x800000
            low = value & 0xFF
            middle = (value >> 8) & 0xFF
            high = (value >> 16) & 0xFF
            if endianness == :little
              bytes << low << middle << high
            else
              bytes << high << middle << low
            end
          end
          bytes
        end

        def normalize_raw_encoding(format, endianness:, signed:, float_domain:)
          byte_order = endianness.to_sym
          unless %i[little big].include?(byte_order)
            raise InvalidParameterError, "endianness must be :little or :big"
          end

          domain = float_domain.to_sym
          unless %i[normalized ieee].include?(domain)
            raise InvalidParameterError, "float_domain must be :normalized or :ieee"
          end
          if format.sample_format == :float
            raise InvalidParameterError, "signed is only valid for PCM raw audio" unless signed.nil?

            return { endianness: byte_order, signed: nil, float_domain: domain }
          end
          unless signed.nil? || signed == true || signed == false
            raise InvalidParameterError, "signed must be true, false, or nil"
          end

          {
            endianness: byte_order,
            signed: signed.nil? ? format.bit_depth != 8 : signed,
            float_domain: domain
          }
        rescue NoMethodError
          raise InvalidParameterError, "endianness and float_domain must be Symbol/String"
        end

        def validate_normalized_float_samples!(samples)
          invalid_index = samples.index { |sample| !sample.finite? || !sample.between?(-1.0, 1.0) }
          return unless invalid_index

          raise InvalidFormatError,
                "normalized raw float sample #{invalid_index} must be finite and within -1.0..1.0"
        end

      end
    end
  end
end
