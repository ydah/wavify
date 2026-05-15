# frozen_string_literal: true

module Wavify
  module Codecs
    # Selects a codec implementation by extension and/or magic bytes.
    class Registry
      # Probe lambdas used to match container signatures from leading bytes.
      MAGIC_PROBES = {
        "RIFF" => lambda do |bytes|
          bytes.bytesize >= 12 && bytes.start_with?("RIFF") && bytes[8, 4] == "WAVE"
        end,
        "fLaC" => ->(bytes) { bytes.start_with?("fLaC") },
        "OggS" => ->(bytes) { bytes.start_with?("OggS") },
        "FORM" => lambda do |bytes|
          bytes.bytesize >= 12 && bytes.start_with?("FORM") && bytes[8, 4] == "AIFF"
        end
      }.freeze

      # Extension-to-codec mapping for path-based detection.
      EXTENSIONS = {
        ".wav" => Wav,
        ".wave" => Wav,
        ".flac" => Flac,
        ".ogg" => OggVorbis,
        ".oga" => OggVorbis,
        ".aiff" => Aiff,
        ".aif" => Aiff,
        ".raw" => Raw,
        ".pcm" => Raw
      }.freeze

      # Probe order for magic-byte detection.
      MAGIC_CODEC_ORDER = [
        ["RIFF", Wav],
        ["fLaC", Flac],
        ["OggS", OggVorbis],
        ["FORM", Aiff]
      ].freeze

      class << self
        # Detects the codec for a path or IO object.
        # Read detection prefers magic bytes when available.
        #
        # @param io_or_path [String, IO]
        # @param filename [String, nil] optional filename hint for IO inputs
        # @return [Class] codec class
        def detect(io_or_path, strict: false, filename: nil)
          detect_for_read(io_or_path, strict: strict, filename: filename)
        end

        # Detects the codec for reading.
        #
        # @param io_or_path [String, IO]
        # @param strict [Boolean] raise when extension and magic bytes disagree
        # @param filename [String, nil] optional filename hint for IO inputs
        # @return [Class] codec class
        def detect_for_read(io_or_path, strict: false, filename: nil)
          extension_codec = detect_by_extension(io_or_path, filename: filename)
          magic_codec = detect_by_magic(io_or_path)
          if strict && extension_codec && magic_codec && extension_codec != magic_codec
            raise InvalidFormatError,
                  "codec mismatch: extension implies #{extension_codec.name}, magic bytes imply #{magic_codec.name}"
          end

          magic_codec || extension_codec || raise_not_found(filename || io_or_path)
        end

        # Detects the codec for writing.
        # Write detection intentionally prefers the target filename extension.
        #
        # @param io_or_path [String, IO]
        # @return [Class] codec class
        def detect_for_write(io_or_path)
          detect_by_extension(io_or_path) || detect_by_magic(io_or_path) || raise_not_found(io_or_path)
        end

        # Registers or replaces a codec for a filename extension.
        #
        # @param extension [String]
        # @param codec [Class]
        # @return [Class] codec
        def register(extension, codec)
          normalized_extension = normalize_extension(extension)
          validate_codec!(codec)
          extensions[normalized_extension] = codec
        end

        # @return [Array<String>] supported extension names without leading dots
        def supported_formats
          extensions.keys.map { |extension| extension.delete_prefix(".") }.uniq.sort.freeze
        end

        private

        def detect_by_extension(io_or_path, filename: nil)
          source = filename || io_or_path
          return unless source.is_a?(String)

          extensions[File.extname(source).downcase]
        end

        def extensions
          @extensions ||= EXTENSIONS.dup
        end

        def normalize_extension(extension)
          unless extension.is_a?(String) && extension.match?(/\A\.?[a-z0-9]+\z/i)
            raise InvalidParameterError, "extension must be a file extension String"
          end

          extension.start_with?(".") ? extension.downcase : ".#{extension.downcase}"
        end

        def validate_codec!(codec)
          required_methods = %i[read write stream_read stream_write metadata]
          missing = required_methods.reject { |method| codec.respond_to?(method) }
          return if missing.empty?

          raise InvalidParameterError, "codec must respond to: #{missing.join(', ')}"
        end

        def detect_by_magic(io_or_path)
          io, close_io = ensure_io(io_or_path)
          return unless io

          probe = io.read(12)
          io.rewind if io.respond_to?(:rewind)
          MAGIC_CODEC_ORDER.each do |magic_key, codec|
            return codec if MAGIC_PROBES.fetch(magic_key).call(probe)
          end

          nil
        ensure
          io.close if close_io && io
        end

        def ensure_io(io_or_path)
          return [io_or_path, false] if io_or_path.respond_to?(:read)
          return [nil, false] unless io_or_path.is_a?(String) && File.file?(io_or_path)

          [File.open(io_or_path, "rb"), true]
        rescue Errno::ENOENT
          [nil, false]
        end

        def raise_not_found(io_or_path)
          raise CodecNotFoundError, "codec not found for input: #{io_or_path.inspect}"
        end
      end
    end

    class << self
      # @see Registry.detect
      def detect(io_or_path, strict: false, filename: nil)
        Registry.detect(io_or_path, strict: strict, filename: filename)
      end

      # @see Registry.register
      def register(extension, codec)
        Registry.register(extension, codec)
      end

      # @see Registry.supported_formats
      def supported_formats
        Registry.supported_formats
      end
    end
  end
end
