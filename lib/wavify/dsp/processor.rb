# frozen_string_literal: true

module Wavify
  module DSP
    # Shared invocation and result contract for stateful audio processors.
    module Processor
      # Maximum number of frames requested from a processor tail at once.
      TAIL_CHUNK_FRAMES = 4_096

      module_function

      def process(processor, buffer)
        result = if processor.respond_to?(:process)
                   processor.process(buffer)
                 elsif processor.respond_to?(:call)
                   processor.call(buffer)
                 elsif processor.respond_to?(:apply)
                   processor.apply(buffer)
                 else
                   raise InvalidParameterError, "processor must respond to :process, :call, or :apply"
                 end
        coerce_buffer(result, "processor")
      end

      def flush(processor, format: nil)
        return [].each unless processor.respond_to?(:flush)

        result = format ? flush_with_format(processor, format) : processor.flush
        each_buffer(result, "processor flush")
      end

      def each_buffer(result, context = "processor")
        return [].each if result.nil?
        return [coerce_buffer(result, context)].each if buffer?(result)
        unless result.respond_to?(:each)
          raise ProcessingError, "#{context} must return Core::SampleBuffer, Audio, an Enumerable of them, or nil"
        end

        result.lazy.map { |item| coerce_buffer(item, context) }
      end

      def coerce_buffer(result, context = "processor")
        return result.buffer if defined?(Wavify::Audio) && result.is_a?(Wavify::Audio)
        return result if result.is_a?(Core::SampleBuffer)

        raise ProcessingError, "#{context} must return Core::SampleBuffer or Audio"
      end

      def build_runtime(processor)
        return processor.build_runtime if processor.respond_to?(:build_runtime)

        runtime = processor.dup
        runtime.reset if runtime.respond_to?(:reset)
        runtime
      rescue TypeError
        raise InvalidParameterError, "stateful processor must implement #build_runtime or support #dup"
      end

      def duration(processor, method_name)
        return 0.0 unless processor.respond_to?(method_name)

        value = processor.public_send(method_name)
        return 0.0 if value.nil?
        unless value.is_a?(Numeric) && value.respond_to?(:finite?) && value.finite? && value >= 0.0
          raise InvalidParameterError, "#{method_name} must return a non-negative finite Numeric"
        end

        value.to_f
      end

      def render(processor, buffer)
        runtime = build_runtime(processor)
        processed = process(runtime, buffer)
        chunks = [processed]
        chunks.concat(flush(runtime, format: processed.format).to_a)
        combined = chunks.reduce { |left, right| left.concat(right) }
        latency_frames = (duration(runtime, :latency) * combined.format.sample_rate).round
        return combined if latency_frames.zero?

        combined.slice(latency_frames, [combined.sample_frame_count - latency_frames, 0].max)
      end

      def buffer?(result)
        result.is_a?(Core::SampleBuffer) || (defined?(Wavify::Audio) && result.is_a?(Wavify::Audio))
      end
      private_class_method :buffer?

      def flush_with_format(processor, format)
        processor.flush(format: format)
      rescue ArgumentError => e
        raise unless unsupported_format_argument?(e)

        processor.flush
      end
      private_class_method :flush_with_format

      def unsupported_format_argument?(error)
        error.message.match?(/unknown keyword: :format|wrong number of arguments \(given 1, expected 0\)/)
      end
      private_class_method :unsupported_format_argument?
    end
  end
end
