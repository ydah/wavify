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
          bytes.bytesize >= 12 && bytes.start_with?("FORM") && %w[AIFF AIFC].include?(bytes[8, 4])
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
        ".aifc" => Aiff,
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

      # Maximum leading-byte window allowed for a custom magic probe.
      MAX_MAGIC_PROBE_SIZE = 65_536

      BUILTIN_MAGIC_ENTRIES = MAGIC_CODEC_ORDER.each_with_index.map do |(magic_key, codec), index|
        {
          extension: nil,
          codec: codec,
          probe: MAGIC_PROBES.fetch(magic_key),
          probe_size: 12,
          priority: 0,
          sequence: index,
          custom: false
        }.freeze
      end.freeze

      CODEC_POSITIONAL_ARITY = {
        read: 1,
        write: 2,
        stream_read: 1,
        stream_write: 1,
        metadata: 1
      }.freeze

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
          magic_codec = if non_rewindable_io?(io_or_path)
                          if strict
                            raise InvalidParameterError, "strict codec detection requires rewindable IO"
                          end
                          unless extension_codec
                            raise InvalidParameterError,
                                  "codec detection requires rewindable IO; pass filename: as a codec hint"
                          end
                        else
                          detect_by_magic(io_or_path)
                        end
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
        def detect_for_write(io_or_path, filename: nil)
          detect_by_extension(io_or_path, filename: filename) || detect_by_magic(io_or_path) || raise_not_found(filename || io_or_path)
        end

        # Resolves an explicit codec class or registered extension name.
        def resolve(codec)
          if codec.respond_to?(:read) && codec.respond_to?(:write)
            validate_codec!(codec)
            return codec
          end

          key = codec.to_s
          normalized = normalize_extension(key)
          extensions_mutex.synchronize { extensions[normalized] } || raise_not_found(codec)
        end

        # Registers or replaces a codec for a filename extension.
        #
        # @param extension [String]
        # @param codec [Class]
        # @return [Class] codec
        def register(extension, codec, magic: nil, priority: 0, probe_size: 12)
          normalized_extension = normalize_extension(extension)
          validate_codec!(codec)
          magic_probe, normalized_probe_size = normalize_magic_probe(magic, probe_size)
          unless priority.is_a?(Integer)
            raise InvalidParameterError, "priority must be an Integer"
          end

          extensions_mutex.synchronize do
            extensions[normalized_extension] = codec
            magic_entries.delete_if { |entry| entry[:custom] && entry[:extension] == normalized_extension }
            if magic_probe
              magic_entries << {
                extension: normalized_extension,
                codec: codec,
                probe: magic_probe,
                probe_size: normalized_probe_size,
                priority: priority,
                sequence: next_magic_sequence,
                custom: true
              }.freeze
            end
          end
          codec
        end

        # Removes a custom codec mapping or restores the built-in mapping.
        def unregister(extension)
          normalized_extension = normalize_extension(extension)
          extensions_mutex.synchronize do
            previous = extensions[normalized_extension]
            if EXTENSIONS.key?(normalized_extension)
              extensions[normalized_extension] = EXTENSIONS.fetch(normalized_extension)
            else
              extensions.delete(normalized_extension)
            end
            magic_entries.delete_if { |entry| entry[:custom] && entry[:extension] == normalized_extension }
            previous
          end
        end

        # @return [Array<String>] supported extension names without leading dots
        def supported_formats
          extension_snapshot.keys.map { |extension| extension.delete_prefix(".") }.uniq.sort.freeze
        end

        # @return [Array<String>] extension names whose codec dependencies are available
        def available_formats
          extension_snapshot.filter_map do |extension, codec|
            next if codec.respond_to?(:available?) && !codec.available?

            extension.delete_prefix(".")
          end.uniq.sort.freeze
        end

        private

        def detect_by_extension(io_or_path, filename: nil)
          source = filename || io_or_path
          return unless source.is_a?(String)

          extensions_mutex.synchronize { extensions[File.extname(source).downcase] }
        end

        def extensions
          @extensions ||= EXTENSIONS.dup
        end

        def magic_entries
          @magic_entries ||= BUILTIN_MAGIC_ENTRIES.dup
        end

        def next_magic_sequence
          @magic_sequence = [@magic_sequence || BUILTIN_MAGIC_ENTRIES.length, BUILTIN_MAGIC_ENTRIES.length].max + 1
        end

        def extension_snapshot
          extensions_mutex.synchronize { extensions.dup }
        end

        def extensions_mutex
          @extensions_mutex ||= Mutex.new
        end

        def normalize_extension(extension)
          unless extension.is_a?(String) && extension.match?(/\A\.?[a-z0-9]+\z/i)
            raise InvalidParameterError, "extension must be a file extension String"
          end

          extension.start_with?(".") ? extension.downcase : ".#{extension.downcase}"
        end

        def validate_codec!(codec)
          missing = CODEC_POSITIONAL_ARITY.keys.reject { |method| codec.respond_to?(method) }
          unless missing.empty?
            raise InvalidParameterError, "codec must respond to: #{missing.join(', ')}"
          end

          invalid = CODEC_POSITIONAL_ARITY.filter_map do |method_name, positional_count|
            method = codec.method(method_name)
            method_name unless accepts_positional_arguments?(method, positional_count)
          end
          unless invalid.empty?
            raise InvalidParameterError,
                  "codec methods have incompatible positional signatures: #{invalid.join(', ')}"
          end

          %i[write stream_write].each do |method_name|
            parameters = codec.method(method_name).parameters
            accepts_format = parameters.any? do |kind, name|
              kind == :rest || (%i[key keyreq keyrest].include?(kind) && (name == :format || kind == :keyrest))
            end
            raise InvalidParameterError, "codec #{method_name} must accept format:" unless accepts_format
          end

          codec
        end

        def accepts_positional_arguments?(method, expected)
          parameters = method.parameters
          return true if parameters.any? { |kind, _| kind == :rest }

          parameters.count { |kind, _| %i[req opt].include?(kind) } >= expected
        end

        def normalize_magic_probe(magic, probe_size)
          return [nil, nil] if magic.nil?
          unless probe_size.is_a?(Integer) && probe_size.between?(1, MAX_MAGIC_PROBE_SIZE)
            raise InvalidParameterError, "probe_size must be an Integer in 1..#{MAX_MAGIC_PROBE_SIZE}"
          end

          if magic.is_a?(String)
            raise InvalidParameterError, "magic String must not be empty" if magic.empty?

            bytes = magic.b.dup.freeze
            return [->(input) { input.start_with?(bytes) }, [probe_size, bytes.bytesize].max]
          end
          unless magic.respond_to?(:call)
            raise InvalidParameterError, "magic must be a non-empty String or callable"
          end

          [magic, probe_size]
        end

        def detect_by_magic(io_or_path)
          io, close_io = ensure_io(io_or_path)
          return unless io

          original_position = io.pos if io.respond_to?(:pos)
          entries = extensions_mutex.synchronize { magic_entries.dup }
          probe_size = entries.map { |entry| entry.fetch(:probe_size) }.max || 12
          probe = io.read(probe_size).to_s
          entries.sort_by { |entry| [-entry.fetch(:priority), -entry.fetch(:sequence)] }.each do |entry|
            matched = entry.fetch(:probe).call(probe)
            unless matched == true || matched == false || matched.nil?
              raise InvalidParameterError, "codec magic probe must return boolean or nil"
            end
            return entry.fetch(:codec) if matched
          end

          nil
        ensure
          if !close_io && original_position && io.respond_to?(:seek)
            io.seek(original_position, IO::SEEK_SET)
          end
          io.close if close_io && io
        end

        def non_rewindable_io?(io_or_path)
          return false unless io_or_path.respond_to?(:read)
          return true unless io_or_path.respond_to?(:pos) && io_or_path.respond_to?(:seek)

          position = io_or_path.pos
          io_or_path.seek(position, IO::SEEK_SET)
          false
        rescue IOError, SystemCallError
          true
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
      def register(extension, codec, **options)
        Registry.register(extension, codec, **options)
      end

      # @see Registry.unregister
      def unregister(extension)
        Registry.unregister(extension)
      end

      # @see Registry.supported_formats
      def supported_formats
        Registry.supported_formats
      end

      # @see Registry.available_formats
      def available_formats
        Registry.available_formats
      end
    end
  end
end
