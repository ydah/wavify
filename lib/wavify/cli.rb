# frozen_string_literal: true

require "optparse"

module Wavify
  # Minimal command-line interface for common Wavify workflows.
  class CLI
    COMMANDS = %w[info convert tone normalize trim chain render timeline formats doctor].freeze

    def self.run(argv = ARGV, stdout: $stdout, stderr: $stderr)
      new(argv, stdout: stdout, stderr: stderr).run
    end

    def initialize(argv, stdout:, stderr:)
      @argv = argv.dup
      @stdout = stdout
      @stderr = stderr
    end

    def run
      command = @argv.shift
      return usage if command.nil? || %w[-h --help help].include?(command)
      return version if command == "--version"

      unless COMMANDS.include?(command)
        @stderr.puts "wavify: unknown command #{command.inspect}"
        return usage(status: 1, output: @stderr)
      end

      options = parse_options!(@argv)
      return usage if options.delete(:help)
      return version if options.delete(:version)

      @options = options
      send("run_#{command}")
      raise InvalidParameterError, "unexpected arguments: #{@argv.join(' ')}" unless @argv.empty?

      0
    rescue Wavify::Error, ArgumentError, SyntaxError => e
      @stderr.puts "wavify: #{e.message}"
      1
    rescue StandardError => e
      @stderr.puts "wavify: unexpected error (#{e.class}): #{e.message}"
      1
    end

    private

    def run_info
      path = require_argument!("input path")
      metadata = Audio.metadata(path)
      format = metadata.fetch(:format)
      @stdout.puts "path: #{path}"
      @stdout.puts "format: #{format.sample_rate}Hz #{format.channels}ch #{format.bit_depth}-bit #{format.sample_format}"
      @stdout.puts "duration: #{metadata[:duration]}"
      @stdout.puts "frames: #{metadata[:sample_frame_count]}"
      Array(metadata[:warnings]).each { |warning| @stdout.puts "warning: #{warning}" }
    end

    def run_convert
      input = require_argument!("input path")
      output = require_argument!("output path")
      audio = Audio.read(input)
      target_format = converted_format(audio.format, @options)
      target = target_format == audio.format ? audio : audio.convert(target_format)
      target.write(output)
      @stdout.puts "converted: #{input} -> #{output}"
    end

    def run_tone
      output = require_argument!("output path")
      format = base_format(@options)
      audio = Audio.tone(
        frequency: @options.fetch(:freq, 440.0),
        duration: @options.fetch(:duration, 1.0),
        waveform: @options.fetch(:waveform, :sine),
        format: format
      )
      audio.write(output)
      @stdout.puts "wrote: #{output}"
    end

    def run_normalize
      input = require_argument!("input path")
      output = require_argument!("output path")
      Audio.read(input).normalize(target_db: @options.fetch(:target, -1.0)).write(output)
      @stdout.puts "normalized: #{input} -> #{output}"
    end

    def run_trim
      input = require_argument!("input path")
      output = require_argument!("output path")
      Audio.read(input).trim(threshold: @options.fetch(:threshold, 0.01)).write(output)
      @stdout.puts "trimmed: #{input} -> #{output}"
    end

    def run_chain
      input = require_argument!("input path")
      output = require_argument!("output path")
      audio = Audio.read(input)
      audio = audio.gain(@options[:gain]) if @options.key?(:gain)
      audio = audio.fade_in(@options[:fade_in]) if @options.key?(:fade_in)
      audio = audio.fade_out(@options[:fade_out]) if @options.key?(:fade_out)
      target_format = converted_format(audio.format, @options)
      audio = audio.convert(target_format) if target_format != audio.format
      audio.write(output)
      @stdout.puts "processed: #{input} -> #{output}"
    end

    def run_render
      input = require_argument!("song path")
      output = require_argument!("output path")
      song = load_song_definition(input, @options)
      song.write(output, default_bars: @options.fetch(:bars, 1))
      @stdout.puts "rendered: #{input} -> #{output}"
    end

    def run_timeline
      input = require_argument!("song path")
      song = load_song_definition(input, @options)
      output = if @options[:json]
                 song.timeline_json(default_bars: @options.fetch(:bars, 1))
               else
                 song.timeline_text(default_bars: @options.fetch(:bars, 1))
               end
      @stdout.puts output
    end

    def run_formats
      @stdout.puts Codecs.supported_formats.join("\n")
    end

    def run_doctor
      @stdout.puts "ruby: #{RUBY_VERSION}"
      @stdout.puts "formats: #{Codecs.supported_formats.join(', ')}"
      @stdout.puts "available formats: #{Codecs.available_formats.join(', ')}"
      check_codec("ogg/vorbis", Codecs::OggVorbis)
    end

    def check_codec(name, codec)
      if codec.available?
        @stdout.puts "#{name}: ok"
      else
        @stdout.puts "#{name}: missing optional gems (add ogg-ruby and vorbis to your Gemfile)"
      end
    end

    def parse_options!(tokens)
      options = {}
      parser = OptionParser.new do |opts|
        opts.on("--freq HZ", Float) { |value| options[:freq] = value }
        opts.on("--duration SECONDS", Float) { |value| options[:duration] = value }
        opts.on("--waveform NAME") { |value| options[:waveform] = value.to_sym }
        opts.on("--sample-rate HZ", Integer) { |value| options[:sample_rate] = value }
        opts.on("--channels COUNT", Integer) { |value| options[:channels] = value }
        opts.on("--bit-depth BITS", Integer) { |value| options[:bit_depth] = value }
        opts.on("--target DB", Float) { |value| options[:target] = value }
        opts.on("--threshold LEVEL", Float) { |value| options[:threshold] = value }
        opts.on("--gain DB", Float) { |value| options[:gain] = value }
        opts.on("--fade-in SECONDS", Float) { |value| options[:fade_in] = value }
        opts.on("--fade-out SECONDS", Float) { |value| options[:fade_out] = value }
        opts.on("--tempo BPM", Float) { |value| options[:tempo] = value }
        opts.on("--swing AMOUNT", Float) { |value| options[:swing] = value }
        opts.on("--beats-per-bar COUNT", Integer) { |value| options[:beats_per_bar] = value }
        opts.on("--bars COUNT", Integer) { |value| options[:bars] = value }
        opts.on("--seed INTEGER", Integer) { |value| options[:seed] = value }
        opts.on("--json") { options[:json] = true }
        opts.on("-h", "--help") { options[:help] = true }
        opts.on("--version") { options[:version] = true }
      end
      parser.parse!(tokens)
      options
    rescue OptionParser::ParseError => e
      raise InvalidParameterError, e.message
    end

    def base_format(options)
      converted_format(Core::Format::CD_QUALITY, options)
    end

    def converted_format(format, options)
      format.with(
        channels: options[:channels],
        sample_rate: options[:sample_rate],
        bit_depth: options[:bit_depth]
      )
    end

    def require_argument!(name)
      value = @argv.shift
      raise InvalidParameterError, "missing #{name}" if value.nil? || value.empty?

      value
    end

    def read_source_file(path)
      File.read(path)
    rescue Errno::ENOENT
      raise InvalidParameterError, "song file not found: #{path}"
    end

    def load_song_definition(path, options)
      source = read_source_file(path)
      DSL.build_definition(
        format: base_format(options),
        tempo: options.fetch(:tempo, 120.0),
        beats_per_bar: options.fetch(:beats_per_bar, 4),
        swing: options.fetch(:swing, 0.5),
        default_bars: options.fetch(:bars, 1),
        random_seed: options.fetch(:seed) { Random.new_seed }
      ) do
        instance_eval(source, path, 1)
      end
    end

    def version
      @stdout.puts Wavify::VERSION
      0
    end

    def usage(status: 0, output: @stdout)
      output.puts "usage: wavify <#{COMMANDS.join('|')}> [options]"
      status
    end
  end
end
