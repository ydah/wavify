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
        def write(_io_or_path, _sample_buffer, format:)
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
        def stream_write(_io_or_path, format:)
          raise NotImplementedError
        end

        # Reads metadata (format and duration-related info) without full decode.
        #
        # @param _io_or_path [String, IO]
        # @return [Hash]
        def metadata(_io_or_path)
          raise NotImplementedError
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

        def read_exact(io, size, message)
          data = io.read(size)
          raise InvalidFormatError, message if data.nil? || data.bytesize != size

          data
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
          return if io.respond_to?(:seek) && io.respond_to?(:pos)

          raise StreamError, "codec requires seekable IO"
        end
      end
    end
  end
end
