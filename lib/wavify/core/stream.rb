# frozen_string_literal: true

module Wavify
  module Core
    # Lazy streaming pipeline for chunk-based audio processing.
    #
    # Instances are typically created via {Wavify::Audio.stream}.
    class Stream
      include Enumerable

      attr_reader :format, :chunk_size

      # @param source [String, IO] input path or IO
      # @param codec [Class] codec class implementing `stream_read/stream_write`
      # @param format [Format, nil] source format (may be inferred later)
      # @param chunk_size [Integer] chunk size in frames
      # @param codec_read_options [Hash] codec-specific options forwarded to `stream_read`
      def initialize(source, codec:, format:, chunk_size: 4096, codec_read_options: {})
        @source = source
        @codec = codec
        @format = format
        @chunk_size = validate_chunk_size!(chunk_size)
        @codec_read_options = validate_codec_read_options!(codec_read_options)
        @pipeline = []
      end

      # Adds a processor to the stream pipeline.
      #
      # Processors may respond to `#call`, `#process`, or `#apply`.
      #
      # @param processor [#call, #process, #apply, nil]
      # @return [Stream] self
      def pipe(processor = nil, &block)
        candidate = processor || block
        unless candidate.respond_to?(:call) || candidate.respond_to?(:process) || candidate.respond_to?(:apply)
          raise InvalidParameterError, "processor must respond to :call, :process, or :apply"
        end

        @pipeline << candidate
        self
      end

      # Iterates processed chunks.
      #
      # @yield [chunk]
      # @yieldparam chunk [SampleBuffer]
      # @return [Enumerator]
      def each_chunk
        return enum_for(:each_chunk) unless block_given?

        @codec.stream_read(@source, chunk_size: @chunk_size, **@codec_read_options) do |chunk|
          @format ||= chunk.format
          yield apply_pipeline(chunk)
        end
      end

      alias each each_chunk

      # Writes the processed stream to a path or writable IO.
      #
      # @param path_or_io [String, IO]
      # @param format [Format, nil] output format (required for raw output if unknown)
      # @return [String, IO] the same target argument
      def write_to(path_or_io, format: nil)
        output_codec = detect_output_codec(path_or_io)
        target_format = resolve_target_format(format, output_codec)

        output_codec.stream_write(path_or_io, format: target_format) do |writer|
          each_chunk do |chunk|
            output_chunk = target_format ? chunk.convert(target_format) : chunk
            writer.call(output_chunk)
          end
        end

        path_or_io
      end

      private

      def apply_pipeline(chunk)
        @pipeline.reduce(chunk) do |current, processor|
          result = if processor.respond_to?(:call)
                     processor.call(current)
                   elsif processor.respond_to?(:process)
                     processor.process(current)
                   else
                     processor.apply(current)
                   end

          if result.is_a?(Audio)
            result.buffer
          elsif result.is_a?(SampleBuffer)
            result
          else
            raise ProcessingError, "stream processor must return Core::SampleBuffer or Audio"
          end
        end
      end

      def detect_output_codec(path_or_io)
        return @codec unless path_or_io.is_a?(String)

        Codecs::Registry.detect(path_or_io)
      end

      def resolve_target_format(format, output_codec)
        return format if format
        return @format if @format

        raise InvalidFormatError, "format is required when writing raw stream output" if output_codec == Codecs::Raw

        nil
      end

      def validate_chunk_size!(chunk_size)
        raise InvalidParameterError, "chunk_size must be a positive Integer" unless chunk_size.is_a?(Integer) && chunk_size.positive?

        chunk_size
      end

      def validate_codec_read_options!(codec_read_options)
        return {} if codec_read_options.nil?
        raise InvalidParameterError, "codec_read_options must be a Hash" unless codec_read_options.is_a?(Hash)

        codec_read_options.dup
      end
    end
  end
end
