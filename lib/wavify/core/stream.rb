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
        @pipeline_names = []
        @tee_targets = []
        @take_duration_seconds = nil
        @drop_duration_seconds = nil
        @enumerated = false
      end

      # Adds a processor to the stream pipeline.
      #
      # Processors may respond to `#process`, `#call`, or `#apply`.
      # Stateful processors may also expose `#reset` and `#flush`.
      #
      # @param processor [#call, #process, #apply, nil]
      # @param name [String, Symbol, nil] optional display name for inspection
      # @return [Stream] self
      def pipe(processor = nil, name: nil, &block)
        candidate = processor || block
        unless candidate.respond_to?(:call) || candidate.respond_to?(:process) || candidate.respond_to?(:apply)
          raise InvalidParameterError, "processor must respond to :call, :process, or :apply"
        end

        @pipeline << candidate
        @pipeline_names << validate_pipeline_name!(name)
        self
      end

      # Adds a block processor for chunk-to-chunk transforms.
      #
      # @param name [String, Symbol, nil] optional display name for inspection
      # @return [Stream] self
      def map_chunks(name: nil, &block)
        raise InvalidParameterError, "map_chunks requires a block" unless block

        pipe(block, name: name || :map_chunks)
      end

      # Limits the source stream to the first duration after any dropped prefix.
      #
      # @param duration [Numeric, Duration] seconds or duration object
      # @return [Stream] self
      def take_duration(duration)
        @take_duration_seconds = coerce_duration_seconds!(duration, "duration")
        self
      end

      # Drops an initial duration from the source stream.
      #
      # @param duration [Numeric, Duration] seconds or duration object
      # @return [Stream] self
      def drop_duration(duration)
        @drop_duration_seconds = coerce_duration_seconds!(duration, "duration")
        self
      end

      # Installs a passive per-chunk level meter.
      #
      # @yield [stats]
      # @yieldparam stats [Hash]
      # @return [Stream] self
      def meter(&block)
        raise InvalidParameterError, "meter requires a block" unless block

        pipe(MeterProcessor.new(block), name: :meter)
      end

      # Installs a passive progress callback based on processed output chunks.
      #
      # @param total_frames [Integer, nil] optional expected output frame count
      # @yield [stats]
      # @yieldparam stats [Hash]
      # @return [Stream] self
      def progress(total_frames: nil, &block)
        raise InvalidParameterError, "progress requires a block" unless block
        if total_frames && (!total_frames.is_a?(Integer) || total_frames.negative?)
          raise InvalidParameterError, "total_frames must be a non-negative Integer"
        end

        pipe(ProgressProcessor.new(block, total_frames: total_frames), name: :progress)
      end

      # Writes processed chunks to an additional output while the stream is consumed.
      #
      # @param path_or_io [String, IO]
      # @param format [Format, nil] optional output format
      # @param codec_options [Hash, nil] codec-specific options forwarded to `stream_write`
      # @return [Stream] self
      def tee(path_or_io, format: nil, codec_options: nil)
        output_codec = detect_output_codec(path_or_io)
        target_format = resolve_target_format(format, output_codec)
        raise InvalidFormatError, "format is required when teeing stream output" unless target_format.is_a?(Format)

        @tee_targets << {
          target: path_or_io,
          codec: output_codec,
          format: target_format,
          codec_options: validate_codec_options!(codec_options, "codec_options")
        }
        self
      end

      # Materializes the processed stream into an Audio object.
      #
      # @return [Audio]
      def to_audio
        output_format = nil
        samples = []
        each_chunk do |chunk|
          output_format ||= chunk.format
          converted = chunk.format == output_format ? chunk : chunk.convert(output_format)
          samples.concat(converted.samples)
        end
        output_format ||= @last_output_format || @format
        raise InvalidFormatError, "stream format is unknown" unless output_format.is_a?(Format)

        Audio.new(SampleBuffer.new(samples, output_format))
      end

      # @return [Array<Object>] registered processors in execution order
      def pipeline
        @pipeline.dup
      end

      # @return [Array<Hash>] processor names and objects in execution order
      def pipeline_steps
        @pipeline.map.with_index do |processor, index|
          {
            name: @pipeline_names.fetch(index),
            processor: processor,
            latency: processor_duration(processor, :latency),
            lookahead: processor_duration(processor, :lookahead),
            tail_duration: processor_duration(processor, :tail_duration)
          }
        end
      end

      # @return [Float] summed processor latency in seconds
      def latency
        @pipeline.sum { |processor| processor_duration(processor, :latency) }
      end

      # @return [Float] summed processor lookahead in seconds
      def lookahead
        @pipeline.sum { |processor| processor_duration(processor, :lookahead) }
      end

      # Reads and processes the stream without writing output.
      #
      # @param format [Format, nil] optional output conversion to validate
      # @return [Hash]
      def dry_run(format: nil)
        raise InvalidFormatError, "format must be Core::Format" if format && !format.is_a?(Format)

        tee_targets = @tee_targets
        @tee_targets = []
        stats = {
          chunks: 0,
          sample_frame_count: 0,
          format: format,
          pipeline: pipeline_steps,
          latency: latency,
          lookahead: lookahead,
          tail_duration: pipeline_tail_duration
        }

        each_chunk do |chunk|
          output_chunk = format ? chunk.convert(format) : chunk
          stats[:chunks] += 1
          stats[:sample_frame_count] += output_chunk.sample_frame_count
          stats[:format] ||= output_chunk.format
        end
        stats[:duration] = stats[:format] ? Duration.from_samples(stats[:sample_frame_count], stats[:format].sample_rate) : nil
        stats
      ensure
        @tee_targets = tee_targets if defined?(tee_targets)
      end

      # Iterates processed chunks.
      #
      # @yield [chunk]
      # @yieldparam chunk [SampleBuffer]
      # @return [Enumerator]
      def each_chunk
        return enum_for(:each_chunk) unless block_given?

        prepare_source_for_enumeration!
        reset_pipeline!
        @last_output_format = nil
        drop_frames = nil
        take_frames = nil
        taken_frames = 0

        with_tee_writers do |tee_writers|
          with_stream_context("stream read", codec: @codec, target: @source) do
            @codec.stream_read(@source, chunk_size: @chunk_size, **@codec_read_options) do |chunk|
              with_stream_context("stream processing", codec: @codec, target: @source) do
                @format ||= chunk.format
                drop_frames ||= duration_frames(@drop_duration_seconds, chunk.format) || 0
                take_frames = duration_frames(@take_duration_seconds, chunk.format) if take_frames.nil? && @take_duration_seconds
                input_chunk, drop_frames, taken_frames = apply_duration_window(
                  chunk,
                  drop_frames: drop_frames,
                  take_frames: take_frames,
                  taken_frames: taken_frames
                )
                next unless input_chunk

                output_chunk = apply_pipeline(input_chunk)
                @last_output_format = output_chunk.format
                write_tee_chunks(output_chunk, tee_writers)
                yield output_chunk
              end
            end
          end

          with_stream_context("stream flush", codec: @codec, target: @source) do
            flush_pipeline do |chunk|
              if take_frames
                remaining_frames = take_frames - taken_frames
                next if remaining_frames <= 0

                chunk = chunk.slice(0, [chunk.sample_frame_count, remaining_frames].min)
                taken_frames += chunk.sample_frame_count
              end
              @last_output_format = chunk.format
              write_tee_chunks(chunk, tee_writers)
              yield chunk
            end
          end
        end
      rescue UserCodeError => e
        raise e.original
      end

      alias each each_chunk

      # Writes the processed stream to a path or writable IO.
      #
      # @param path_or_io [String, IO]
      # @param format [Format, nil] output format (required for raw output if unknown)
      # @param codec_options [Hash] codec-specific options forwarded to `stream_write`
      # @param overwrite [Boolean] whether existing path output may be replaced
      # @return [String, IO] the same target argument
      def write_to(path_or_io, format: nil, codec_options: nil, overwrite: true)
        validate_overwrite!(path_or_io, overwrite)
        output_codec = detect_output_codec(path_or_io)
        target_format = resolve_target_format(format, output_codec)
        options = validate_codec_options!(codec_options, "codec_options")

        with_stream_context("stream write", codec: output_codec, target: path_or_io) do
          output_codec.stream_write(path_or_io, format: target_format, **options) do |writer|
            each_chunk do |chunk|
              output_chunk = target_format ? chunk.convert(target_format) : chunk
              with_stream_context("stream write", codec: output_codec, target: path_or_io) do
                writer.call(output_chunk)
              end
            end
          end
        end

        path_or_io
      end

      private

      # Passive stream processor that reports per-chunk audio levels.
      class MeterProcessor
        def initialize(callback)
          @callback = callback
        end

        def process(chunk)
          float_chunk = chunk.convert(chunk.format.with(sample_format: :float, bit_depth: 32))
          peak = float_chunk.samples.map(&:abs).max || 0.0
          rms = if float_chunk.samples.empty?
                  0.0
                else
                  Math.sqrt(float_chunk.samples.sum { |sample| sample * sample } / float_chunk.samples.length)
                end
          @callback.call(
            format: chunk.format,
            sample_frame_count: chunk.sample_frame_count,
            duration: chunk.duration,
            peak_amplitude: peak,
            rms_amplitude: rms,
            peak_dbfs: amplitude_to_dbfs(peak),
            rms_dbfs: amplitude_to_dbfs(rms)
          )
          chunk
        rescue StandardError => e
          raise UserCodeError, e
        end

        private

        def amplitude_to_dbfs(amplitude)
          return -Float::INFINITY if amplitude <= 0.0

          20.0 * Math.log10(amplitude)
        end
      end

      # Passive stream processor that reports cumulative processed frames.
      class ProgressProcessor
        def initialize(callback, total_frames:)
          @callback = callback
          @total_frames = total_frames
          @processed_frames = 0
        end

        def reset
          @processed_frames = 0
        end

        def process(chunk)
          @processed_frames += chunk.sample_frame_count
          stats = {
            format: chunk.format,
            sample_frame_count: @processed_frames,
            duration: Duration.from_samples(@processed_frames, chunk.format.sample_rate)
          }
          stats[:total_frames] = @total_frames if @total_frames
          stats[:progress] = @processed_frames.to_f / @total_frames if @total_frames&.positive?
          @callback.call(stats)
          chunk
        rescue StandardError => e
          raise UserCodeError, e
        end
      end

      class UserCodeError < StandardError
        attr_reader :original

        def initialize(original)
          @original = original
          super(original.message)
          set_backtrace(original.backtrace)
        end
      end

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
      rescue UserCodeError
        raise
      rescue StandardError => e
        raise UserCodeError, e
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

      def processor_duration(processor, method_name)
        return 0.0 unless processor.respond_to?(method_name)

        value = processor.public_send(method_name)
        return 0.0 if value.nil?
        unless value.is_a?(Numeric) && value.respond_to?(:finite?) && value.finite? && value >= 0.0
          raise InvalidParameterError, "#{method_name} must return a non-negative finite Numeric"
        end

        value.to_f
      end

      def pipeline_tail_duration
        @pipeline.map { |processor| processor_duration(processor, :tail_duration) }.max || 0.0
      end

      def apply_duration_window(chunk, drop_frames:, take_frames:, taken_frames:)
        start_frame = [drop_frames, chunk.sample_frame_count].min
        drop_frames -= start_frame
        available_frames = chunk.sample_frame_count - start_frame
        return [nil, drop_frames, taken_frames] if available_frames.zero?

        frame_length = available_frames
        if take_frames
          remaining_frames = take_frames - taken_frames
          return [nil, drop_frames, taken_frames] if remaining_frames <= 0

          frame_length = [frame_length, remaining_frames].min
        end

        windowed = chunk.slice(start_frame, frame_length)
        taken_frames += windowed.sample_frame_count
        [windowed, drop_frames, taken_frames]
      end

      def duration_frames(duration_seconds, format)
        return nil unless duration_seconds

        (duration_seconds * format.sample_rate).round
      end

      def with_tee_writers(targets = @tee_targets, writers = [], &block)
        return yield(writers) if targets.empty?

        target = targets.first
        with_stream_context("stream tee", codec: target[:codec], target: target[:target]) do
          target[:codec].stream_write(target[:target], format: target[:format], **target[:codec_options]) do |writer|
            with_tee_writers(targets.drop(1), writers + [target.merge(writer: writer)], &block)
          end
        end
      end

      def write_tee_chunks(chunk, tee_writers)
        tee_writers.each do |target|
          output_chunk = chunk.format == target[:format] ? chunk : chunk.convert(target[:format])
          target[:writer].call(output_chunk)
        end
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

        Codecs::Registry.detect_for_write(path_or_io)
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

      def validate_overwrite!(path_or_io, overwrite)
        raise InvalidParameterError, "overwrite must be true or false" unless overwrite == true || overwrite == false
        return if overwrite || !path_or_io.is_a?(String) || !File.exist?(path_or_io)

        raise InvalidParameterError, "output file already exists: #{path_or_io}"
      end

      def validate_pipeline_name!(name)
        return nil if name.nil?
        return name.to_s if name.is_a?(String) || name.is_a?(Symbol)

        raise InvalidParameterError, "name must be a String or Symbol"
      end

      def coerce_duration_seconds!(duration, name)
        seconds = case duration
                  when Duration
                    duration.total_seconds
                  when Numeric
                    duration.to_f
                  else
                    raise InvalidParameterError, "#{name} must be Numeric or Core::Duration"
                  end
        raise InvalidParameterError, "#{name} must be non-negative" if seconds.negative?

        seconds
      end

      def with_stream_context(operation, codec:, target:)
        yield
      rescue UserCodeError, StreamError
        raise
      rescue StandardError => e
        raise StreamError, stream_error_message(operation, codec: codec, target: target, error: e)
      end

      def stream_error_message(operation, codec:, target:, error:)
        "#{operation} failed " \
          "(codec=#{stream_codec_name(codec)}, target=#{stream_target_label(target)}, chunk_size=#{@chunk_size}): " \
          "#{error.class}: #{error.message}"
      end

      def stream_codec_name(codec)
        name = codec.respond_to?(:name) ? codec.name : nil
        return name unless name.nil? || name.empty?

        codec.to_s
      end

      def stream_target_label(target)
        return target if target.is_a?(String)
        return target.path if target.respond_to?(:path)

        target.class.name || target.class.to_s
      end

      def prepare_source_for_enumeration!
        if @enumerated && !@source.is_a?(String)
          unless @source.respond_to?(:rewind)
            raise StreamError, "IO stream source cannot be enumerated more than once because it is not rewindable"
          end

          @source.rewind
        end
        @enumerated = true
      end
    end
  end
end
