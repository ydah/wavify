# frozen_string_literal: true

module Wavify
  # Catalog and loader for optional adapter gems that live outside the core gem.
  module Adapters
    AdapterSpec = Struct.new(:name, :kind, :gem_name, :require_path, :formats, :summary, keyword_init: true)

    KNOWN = [
      AdapterSpec.new(
        name: :ffmpeg,
        kind: :codec,
        gem_name: "wavify-ffmpeg",
        require_path: "wavify/ffmpeg",
        formats: %w[mp3 aac m4a wav flac ogg],
        summary: "FFmpeg-backed codec adapter for formats that should not be mandatory core dependencies."
      ),
      AdapterSpec.new(
        name: :mp3,
        kind: :codec,
        gem_name: "wavify-mp3",
        require_path: "wavify/mp3",
        formats: %w[mp3],
        summary: "MP3 codec adapter."
      ),
      AdapterSpec.new(
        name: :midi,
        kind: :sequencer,
        gem_name: "wavify-midi",
        require_path: "wavify/midi",
        formats: %w[mid midi],
        summary: "MIDI import/export adapter for sequencer timelines."
      ),
      AdapterSpec.new(
        name: :spectrogram,
        kind: :analysis,
        gem_name: "wavify-spectrogram",
        require_path: "wavify/spectrogram",
        formats: %w[png json],
        summary: "Spectrogram and FFT analysis adapter."
      )
    ].freeze

    class << self
      # @return [Array<AdapterSpec>]
      def known
        KNOWN.dup
      end

      # @param name [String, Symbol]
      # @return [AdapterSpec, nil]
      def find(name)
        normalized = normalize_name(name)
        KNOWN.find { |adapter| adapter.name == normalized }
      end

      # Requires an optional adapter gem and lets it register itself.
      #
      # @param name [String, Symbol]
      # @return [true]
      def load(name)
        adapter = find(name)
        raise InvalidParameterError, "unknown adapter: #{name.inspect}" unless adapter

        require adapter.require_path
        true
      rescue LoadError
        raise UnsupportedFormatError,
              "adapter #{adapter.name} is not installed; add gem #{adapter.gem_name.inspect} " \
              "and require #{adapter.require_path.inspect}"
      end

      private

      def normalize_name(name)
        name.to_sym
      rescue NoMethodError
        raise InvalidParameterError, "adapter name must be String or Symbol"
      end
    end
  end
end
