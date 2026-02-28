# frozen_string_literal: true

require "benchmark"
require "fileutils"
require_relative "../lib/wavify"

module WavifyBenchmarks
  module Helper
    module_function

    TMP_DIR = File.expand_path("../tmp/benchmarks", __dir__)

    def int_env(name, default)
      value = ENV.fetch(name, nil)
      return default if value.nil? || value.empty?

      Integer(value)
    rescue ArgumentError
      default
    end

    def float_env(name, default)
      value = ENV.fetch(name, nil)
      return default if value.nil? || value.empty?

      Float(value)
    rescue ArgumentError
      default
    end

    def bool_env(name, default: false)
      value = ENV.fetch(name, nil)
      return default if value.nil?

      %w[1 true yes on].include?(value.downcase)
    end

    def tmp_dir
      FileUtils.mkdir_p(TMP_DIR)
      TMP_DIR
    end

    def banner(title)
      puts
      puts "== #{title} =="
    end

    def measure(label)
      result = nil
      elapsed = Benchmark.realtime do
        result = yield
      end
      puts format("  %<label>-32s %<elapsed>8.4fs", label: label, elapsed: elapsed)
      [elapsed, result]
    end

    def rss_kb
      value = `ps -o rss= -p #{Process.pid}`.to_s.strip
      return nil if value.empty?

      Integer(value)
    rescue StandardError
      nil
    end

    def file_size_mb(path)
      return 0.0 unless File.file?(path)

      File.size(path) / (1024.0 * 1024.0)
    end

    def float_stereo_format(sample_rate: 44_100)
      Wavify::Core::Format.new(channels: 2, sample_rate: sample_rate, bit_depth: 32, sample_format: :float)
    end

    def pcm_stereo_format(sample_rate: 44_100)
      Wavify::Core::Format.new(channels: 2, sample_rate: sample_rate, bit_depth: 16, sample_format: :pcm)
    end

    def demo_audio(duration_seconds:, format: float_stereo_format)
      raise ArgumentError, "duration_seconds must be > 0" unless duration_seconds.is_a?(Numeric) && duration_seconds.positive?

      lead = Wavify::Audio.tone(frequency: 220.0, duration: duration_seconds, waveform: :sawtooth, format: format).gain(-14)
      harmony = Wavify::Audio.tone(frequency: 330.0, duration: duration_seconds, waveform: :triangle, format: format).gain(-18)
      noise = Wavify::Audio.tone(frequency: 1.0, duration: duration_seconds, waveform: :white_noise, format: format).gain(-34)

      Wavify::Audio.mix(lead, harmony, noise)
                   .apply(Wavify::Effects::Chorus.new(rate: 0.25, depth: 0.2, mix: 0.15))
                   .normalize(target_db: -3.0)
    end

    def print_config(config)
      config.each do |key, value|
        puts "  #{key}: #{value}"
      end
    end

    def maybe_cleanup(*paths)
      return if bool_env("KEEP_BENCH_FILES", default: false)

      paths.each do |path|
        File.delete(path) if File.file?(path)
      end
    end

    def gain_chunk_processor(db)
      lambda do |chunk|
        Wavify::Audio.new(chunk).gain(db).buffer
      end
    end
  end
end
