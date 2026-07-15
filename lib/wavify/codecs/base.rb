# frozen_string_literal: true

module Wavify
  # Codec implementations for supported container/audio formats.
  module Codecs
    # Abstract codec interface used by {Registry} and {Wavify::Audio}.
    #
    # Concrete codecs implement the class methods below.
    class Base
      class << self
        # Returns whether this codec can read the given path/IO.
        #
        # @param _io_or_path [String, IO]
        # @return [Boolean]
        def can_read?(_io_or_path)
          raise NotImplementedError
        end

        # Reads a full audio buffer from a path/IO.
        #
        # @param _io_or_path [String, IO]
        # @param format [Wavify::Core::Format, nil]
        # @return [Wavify::Core::SampleBuffer]
        def read(_io_or_path, format: nil)
          raise NotImplementedError
        end

        # Writes a full audio buffer to a path/IO.
        #
        # @param _io_or_path [String, IO]
        # @param _sample_buffer [Wavify::Core::SampleBuffer]
        # @param format [Wavify::Core::Format]
        # @return [String, IO]
        def write(_io_or_path, _sample_buffer, format:, **_codec_options)
          raise NotImplementedError
        end

        # Streams decoded audio as chunked sample buffers.
        #
        # @param _io_or_path [String, IO]
        # @param chunk_size [Integer] chunk size in frames
        # @return [Enumerator]
        def stream_read(_io_or_path, chunk_size: 4096)
          raise NotImplementedError
        end

        # Streams encoded chunks to a path/IO through a yielded writer.
        #
        # @param _io_or_path [String, IO]
        # @param format [Wavify::Core::Format]
        # @return [Enumerator, String, IO]
        def stream_write(_io_or_path, format:, **_codec_options)
          raise NotImplementedError
        end

        # Reads metadata (format and duration-related info) without full decode.
        #
        # @param _io_or_path [String, IO]
        # @return [Hash]
        def metadata(_io_or_path)
          raise NotImplementedError
        end

        # Returns whether optional runtime dependencies for this codec are present.
        #
        # @return [Boolean]
        def available?
          true
        end

        private

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

        def prepare_output!(io, owned:)
          return io.pos if owned
          return nil unless io.respond_to?(:pos)

          start_position = io.pos
          if io.respond_to?(:size) && io.size > start_position && !io.respond_to?(:truncate)
            raise StreamError, "caller-owned IO with trailing data must support truncate"
          end
          start_position
        rescue IOError, SystemCallError => e
          raise StreamError, "output IO position is unavailable: #{e.message}"
        end

        def finalize_output!(io, owned:)
          io.flush if io.respond_to?(:flush)
          return unless io.respond_to?(:pos)

          end_position = io.pos
          io.truncate(end_position) if !owned && io.respond_to?(:truncate)
        rescue IOError, SystemCallError => e
          raise StreamError, "failed to finalize output IO: #{e.message}"
        end

        def read_exact(io, size, message)
          data = +"".b
          while data.bytesize < size
            chunk = io.read(size - data.bytesize)
            break if chunk.nil? || chunk.empty?

            data << chunk
          end
          raise InvalidFormatError, message if data.bytesize != size

          data
        end

        def read_to_end(io, chunk_size: 16_384)
          data = +"".b
          loop do
            chunk = io.read(chunk_size)
            break if chunk.nil? || chunk.empty?

            data << chunk
          end
          data
        end

        def probe_bytes(io, size)
          ensure_seekable!(io)
          original_position = io.pos
          data = +"".b
          while data.bytesize < size
            chunk = io.read(size - data.bytesize)
            break if chunk.nil? || chunk.empty?

            data << chunk
          end
          data
        ensure
          io.seek(original_position, IO::SEEK_SET) if defined?(original_position) && original_position
        end

        def write_all(io, data)
          bytes = data.b
          offset = 0
          while offset < bytes.bytesize
            written = io.write(bytes.byteslice(offset, bytes.bytesize - offset))
            unless written.is_a?(Integer) && written.positive?
              raise IOError, "write returned #{written.inspect} before all bytes were written"
            end

            offset += written
          end
          bytes.bytesize
        end

        def skip_bytes(io, count)
          return if count.zero?

          if io.respond_to?(:seek)
            io.seek(count, IO::SEEK_CUR)
          else
            discarded = io.read(count)
            raise InvalidFormatError, "truncated chunk body" unless discarded && discarded.bytesize == count
          end
        end

        def ensure_seekable!(io)
          if io.respond_to?(:seek) && io.respond_to?(:pos)
            position = io.pos
            io.seek(position, IO::SEEK_SET)
            return
          end

          raise StreamError, "codec requires seekable IO"
        rescue IOError, SystemCallError => e
          raise StreamError, "codec requires seekable IO: #{e.message}"
        end

        def validate_no_codec_options!(codec_options, operation:)
          return if codec_options.empty?

          names = codec_options.keys.map(&:inspect).join(", ")
          raise InvalidParameterError, "unsupported #{operation} codec_options: #{names}"
        end
      end
    end
  end
end
