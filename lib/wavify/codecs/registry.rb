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
        #
        # @param io_or_path [String, IO]
        # @return [Class] codec class
        def detect(io_or_path)
          detect_by_extension(io_or_path) || detect_by_magic(io_or_path) || raise_not_found(io_or_path)
        end

        private

        def detect_by_extension(io_or_path)
          return unless io_or_path.is_a?(String)

          EXTENSIONS[File.extname(io_or_path).downcase]
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
  end
end
