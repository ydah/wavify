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
      # Processors may respond to `#process`, `#call`, or `#apply`.
      # Stateful processors may also expose `#reset` and `#flush`.
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

      # @return [Array<Object>] registered processors in execution order
      def pipeline
        @pipeline.dup
      end

      # Iterates processed chunks.
      #
      # @yield [chunk]
      # @yieldparam chunk [SampleBuffer]
      # @return [Enumerator]
      def each_chunk
        return enum_for(:each_chunk) unless block_given?

        reset_pipeline!
        @last_output_format = nil

        @codec.stream_read(@source, chunk_size: @chunk_size, **@codec_read_options) do |chunk|
          @format ||= chunk.format
          output_chunk = apply_pipeline(chunk)
          @last_output_format = output_chunk.format
          yield output_chunk
        end

        flush_pipeline do |chunk|
          @last_output_format = chunk.format
          yield chunk
        end
      end

      alias each each_chunk

      # Writes the processed stream to a path or writable IO.
      #
      # @param path_or_io [String, IO]
      # @param format [Format, nil] output format (required for raw output if unknown)
      # @param codec_options [Hash] codec-specific options forwarded to `stream_write`
      # @return [String, IO] the same target argument
      def write_to(path_or_io, format: nil, codec_options: nil)
        output_codec = detect_output_codec(path_or_io)
        target_format = resolve_target_format(format, output_codec)
        options = validate_codec_options!(codec_options, "codec_options")

        output_codec.stream_write(path_or_io, format: target_format, **options) do |writer|
          each_chunk do |chunk|
            output_chunk = target_format ? chunk.convert(target_format) : chunk
            writer.call(output_chunk)
          end
        end

        path_or_io
      end

      private

      def apply_pipeline(chunk, start_index: 0)
        @pipeline.drop(start_index).reduce(chunk) do |current, processor|
          coerce_processor_result(invoke_processor(processor, current), "stream processor")
        end
      end

      def invoke_processor(processor, chunk)
        if processor.respond_to?(:process)
          processor.process(chunk)
        elsif processor.respond_to?(:call)
          processor.call(chunk)
        else
          processor.apply(chunk)
        end
      end

      def reset_pipeline!
        @pipeline.each { |processor| processor.reset if processor.respond_to?(:reset) }
      end

      def flush_pipeline
        @pipeline.each_with_index do |processor, index|
          flush_processor(processor).each do |chunk|
            yield apply_pipeline(chunk, start_index: index + 1)
          end
        end
      end

      def flush_processor(processor)
        return [] unless processor.respond_to?(:flush)

        result = if flush_accepts_format?(processor) && flush_format
                   processor.flush(format: flush_format)
                 else
                   processor.flush
                 end
        normalize_processor_results(result, "stream processor flush")
      end

      def flush_accepts_format?(processor)
        processor.method(:flush).parameters.any? do |kind, name|
          (%i[key keyreq].include?(kind) && name == :format) || kind == :keyrest
        end
      end

      def flush_format
        @last_output_format || @format
      end

      def normalize_processor_results(result, context)
        return [] if result.nil?

        return result.map { |item| coerce_processor_result(item, context) } if result.is_a?(Array)
        return [coerce_processor_result(result, context)] if result.is_a?(Audio) || result.is_a?(SampleBuffer)

        if result.respond_to?(:each)
          return result.map { |item| coerce_processor_result(item, context) }
        end

        raise ProcessingError, "#{context} must return Core::SampleBuffer, Audio, an Enumerable of them, or nil"
      end

      def coerce_processor_result(result, context)
        if result.is_a?(Audio)
          result.buffer
        elsif result.is_a?(SampleBuffer)
          result
        else
          raise ProcessingError, "#{context} must return Core::SampleBuffer or Audio"
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
        validate_codec_options!(codec_read_options, "codec_read_options")
      end

      def validate_codec_options!(codec_options, name)
        return {} if codec_options.nil?
        raise InvalidParameterError, "#{name} must be a Hash" unless codec_options.is_a?(Hash)

        invalid_keys = codec_options.keys.reject { |key| key.is_a?(Symbol) }
        unless invalid_keys.empty?
          raise InvalidParameterError, "#{name} keys must be Symbols: #{invalid_keys.map(&:inspect).join(', ')}"
        end

        codec_options.dup
      end
    end
  end
end
