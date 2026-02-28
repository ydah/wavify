#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "yaml"
require "tempfile"

require_relative "../lib/wavify"

module Wavify
  module Tools
    class FixtureWriter
      def initialize(yaml_dir:, audio_dir:)
        @yaml_dir = yaml_dir
        @audio_dir = audio_dir
      end

      def run
        FileUtils.mkdir_p(@audio_dir)
        yaml_files.each { |path| write_file(path) }
      end

      private

      def yaml_files
        Dir.glob(File.join(@yaml_dir, "*.yml")).sort
      end

      def write_file(path)
        yaml = YAML.safe_load_file(path)
        fixtures = yaml.fetch("fixtures")
        fixtures.each { |fixture| write_fixture(fixture) }
      end

      def write_fixture(fixture)
        name = fixture.fetch("name")
        kind = fixture.fetch("kind", "valid")
        output_path = File.join(@audio_dir, name)

        case kind
        when "valid"
          write_valid_fixture(output_path, fixture)
        when "invalid_no_riff"
          File.binwrite(output_path, "BROKEN")
        when "invalid_truncated"
          write_truncated_fixture(output_path, fixture)
        else
          raise Wavify::InvalidParameterError, "unsupported fixture kind: #{kind.inspect}"
        end
      end

      def write_valid_fixture(path, fixture)
        format = build_format(fixture.fetch("format"))
        samples = fixture.fetch("samples")
        buffer = Wavify::Core::SampleBuffer.new(samples, format)
        Wavify::Codecs::Wav.write(path, buffer)
      end

      def write_truncated_fixture(path, fixture)
        Tempfile.create(["wavify_fixture", ".wav"]) do |tmp|
          write_valid_fixture(tmp.path, fixture)
          bytes = File.binread(tmp.path)
          truncated = bytes[0, [bytes.bytesize / 2, 1].max]
          File.binwrite(path, truncated)
        end
      end

      def build_format(params)
        Wavify::Core::Format.new(
          channels: params.fetch("channels"),
          sample_rate: params.fetch("sample_rate"),
          bit_depth: params.fetch("bit_depth"),
          sample_format: params.fetch("sample_format", "pcm").to_sym
        )
      end
    end
  end
end

root = File.expand_path("..", __dir__)
writer = Wavify::Tools::FixtureWriter.new(
  yaml_dir: File.join(root, "spec/fixtures/yaml"),
  audio_dir: File.join(root, "spec/fixtures/audio")
)
writer.run
