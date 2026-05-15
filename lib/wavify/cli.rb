# frozen_string_literal: true

module Wavify
  # Minimal command-line interface for common Wavify workflows.
  class CLI
    COMMANDS = %w[info convert tone normalize trim chain render formats doctor].freeze

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

      unless COMMANDS.include?(command)
        @stderr.puts "wavify: unknown command #{command.inspect}"
        return usage
      end

      send("run_#{command}")
      0
    rescue Wavify::Error, ArgumentError, SyntaxError => e
      @stderr.puts "wavify: #{e.message}"
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
    end

    def run_convert
      input = require_argument!("input path")
      output = require_argument!("output path")
      options = parse_options(@argv)
      audio = Audio.read(input)
      target_format = converted_format(audio.format, options)
      target = target_format == audio.format ? audio : audio.convert(target_format)
      target.write(output)
      @stdout.puts "converted: #{input} -> #{output}"
    end

    def run_tone
      options = parse_options(@argv)
      output = options.delete(:output) || require_argument!("output path")
      format = base_format(options)
      audio = Audio.tone(
        frequency: options.fetch(:freq, 440.0),
        duration: options.fetch(:duration, 1.0),
        waveform: options.fetch(:waveform, :sine),
        format: format
      )
      audio.write(output)
      @stdout.puts "wrote: #{output}"
    end

    def run_normalize
      input = require_argument!("input path")
      output = require_argument!("output path")
      options = parse_options(@argv)
      Audio.read(input).normalize(target_db: options.fetch(:target, -1.0)).write(output)
      @stdout.puts "normalized: #{input} -> #{output}"
    end

    def run_trim
      input = require_argument!("input path")
      output = require_argument!("output path")
      options = parse_options(@argv)
      Audio.read(input).trim(threshold: options.fetch(:threshold, 0.01)).write(output)
      @stdout.puts "trimmed: #{input} -> #{output}"
    end

    def run_chain
      input = require_argument!("input path")
      output = require_argument!("output path")
      options = parse_options(@argv)
      audio = Audio.read(input)
      audio = audio.gain(options[:gain]) if options.key?(:gain)
      audio = audio.fade_in(options[:fade_in]) if options.key?(:fade_in)
      audio = audio.fade_out(options[:fade_out]) if options.key?(:fade_out)
      target_format = converted_format(audio.format, options)
      audio = audio.convert(target_format) if target_format != audio.format
      audio.write(output)
      @stdout.puts "processed: #{input} -> #{output}"
    end

    def run_render
      input = require_argument!("song path")
      output = require_argument!("output path")
      options = parse_options(@argv)
      source = read_source_file(input)
      song = DSL.build_definition(
        format: base_format(options),
        tempo: options.fetch(:tempo, 120.0),
        beats_per_bar: options.fetch(:beats_per_bar, 4),
        default_bars: options.fetch(:bars, 1)
      ) do
        instance_eval(source, input, 1)
      end
      song.write(output, default_bars: options.fetch(:bars, 1))
      @stdout.puts "rendered: #{input} -> #{output}"
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

    def parse_options(tokens)
      options = {}
      until tokens.empty?
        token = tokens.shift
        case token
        when "--freq"
          options[:freq] = Float(require_option_value!(token, tokens))
        when "--duration"
          options[:duration] = Float(require_option_value!(token, tokens))
        when "--waveform"
          options[:waveform] = require_option_value!(token, tokens).to_sym
        when "--sample-rate"
          options[:sample_rate] = Integer(require_option_value!(token, tokens))
        when "--channels"
          options[:channels] = Integer(require_option_value!(token, tokens))
        when "--bit-depth"
          options[:bit_depth] = Integer(require_option_value!(token, tokens))
        when "--target"
          options[:target] = Float(require_option_value!(token, tokens))
        when "--threshold"
          options[:threshold] = Float(require_option_value!(token, tokens))
        when "--gain"
          options[:gain] = Float(require_option_value!(token, tokens))
        when "--fade-in"
          options[:fade_in] = Float(require_option_value!(token, tokens))
        when "--fade-out"
          options[:fade_out] = Float(require_option_value!(token, tokens))
        when "--tempo"
          options[:tempo] = Float(require_option_value!(token, tokens))
        when "--beats-per-bar"
          options[:beats_per_bar] = Integer(require_option_value!(token, tokens))
        when "--bars"
          options[:bars] = Integer(require_option_value!(token, tokens))
        else
          if token.start_with?("--")
            raise InvalidParameterError, "unknown option #{token}"
          end

          options[:output] = token
        end
      end
      options
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

    def require_option_value!(option, tokens)
      value = tokens.shift
      raise InvalidParameterError, "missing value for #{option}" if value.nil? || value.empty?

      value
    end

    def read_source_file(path)
      File.read(path)
    rescue Errno::ENOENT
      raise InvalidParameterError, "song file not found: #{path}"
    end

    def usage
      @stdout.puts "usage: wavify <#{COMMANDS.join('|')}> [options]"
      1
    end
  end
end
