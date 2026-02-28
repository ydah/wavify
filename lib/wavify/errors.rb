# frozen_string_literal: true

module Wavify
  # Base error class for all Wavify-specific exceptions.
  class Error < StandardError; end

  # Base class for format and codec-related errors.
  class FormatError < Error; end
  # Raised when input/output data is malformed for a supported format.
  class InvalidFormatError < FormatError; end
  # Raised when a format is recognized but not supported by the implementation.
  class UnsupportedFormatError < FormatError; end
  # Raised when no codec can be selected for an input/output target.
  class CodecNotFoundError < FormatError; end

  # Base class for processing pipeline failures.
  class ProcessingError < Error; end
  # Raised when sample buffer conversion fails.
  class BufferConversionError < ProcessingError; end
  # Raised when a streaming operation cannot proceed.
  class StreamError < ProcessingError; end

  # Base class for DSP parameter/processing errors.
  class DSPError < Error; end
  # Raised when method parameters are invalid.
  class InvalidParameterError < DSPError; end

  # Base class for sequencer and DSL-related errors.
  class SequencerError < Error; end
  # Raised when rhythmic pattern notation is invalid.
  class InvalidPatternError < SequencerError; end
  # Raised when note/chord notation is invalid.
  class InvalidNoteError < SequencerError; end
end
