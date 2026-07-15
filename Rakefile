# frozen_string_literal: true

require "bundler/gem_tasks"
require "fileutils"
require "json"
require "rubocop/rake_task"
require "rspec/core/rake_task"
require "rbconfig"
require "tmpdir"
require_relative "tools/yard_coverage"

RSpec::Core::RakeTask.new(:spec)
RuboCop::RakeTask.new(:lint) do |task|
  task.options = ["--cache", "false"]
end

namespace :types do
  desc "Validate RBS signatures"
  task :validate do
    ruby = RbConfig.ruby
    success = system(ruby, "-S", "bundle", "exec", "rbs", "validate")
    abort("RBS validation failed") unless success
  end
end

namespace :spec do
  desc "Generate audio fixtures from YAML definitions"
  task :create_fixtures do
    ruby = RbConfig.ruby
    success = system(ruby, File.expand_path("tools/fixture_writer.rb", __dir__))
    abort("fixture generation failed") unless success
  end

  desc "Run specs with line, branch, and per-file SimpleCov coverage gates"
  task :coverage do
    ruby = RbConfig.ruby
    env = {
      "COVERAGE" => "1",
      "SIMPLECOV_BRANCH" => ENV.fetch("SIMPLECOV_BRANCH", "1")
    }
    %w[
      COVERAGE_MINIMUM
      COVERAGE_BRANCH_MINIMUM
      COVERAGE_MINIMUM_PER_FILE
      COVERAGE_BRANCH_MINIMUM_PER_FILE
    ].each do |name|
      env[name] = ENV[name] if ENV[name]
    end

    success = system(env, ruby, "-S", "bundle", "exec", "rspec")
    abort("coverage run failed") unless success
  end
end

desc "Run the local quality gate (specs, lint, signatures, and docs)"
task check: [:spec, :lint, "types:validate", "docs:check"]

task default: :check

namespace :bench do
  def benchmark_scripts
    {
      wav_io: "benchmarks/wav_io_benchmark.rb",
      dsp: "benchmarks/dsp_effects_benchmark.rb",
      flac: "benchmarks/flac_benchmark.rb",
      stream: "benchmarks/streaming_memory_benchmark.rb"
    }.freeze
  end

  def run_benchmark_script(path, env: {})
    ruby = RbConfig.ruby
    success = system(env, ruby, File.expand_path(path, __dir__))
    abort("benchmark failed: #{path}") unless success
  end

  def benchmark_report_dir(name)
    File.expand_path(ENV.fetch("BENCH_DIR", "tmp/benchmarks/#{name}"), __dir__)
  end

  def run_benchmark_reports(dir)
    FileUtils.mkdir_p(dir)
    benchmark_scripts.each do |name, path|
      run_benchmark_script(path, env: { "BENCH_JSON" => File.join(dir, "#{name}.json") })
    end
  end

  def compare_benchmark_reports!(baseline_dir, current_dir)
    threshold = Float(ENV.fetch("BENCH_THRESHOLD", "1.2"))
    benchmark_scripts.each_key do |name|
      baseline = JSON.parse(File.read(File.join(baseline_dir, "#{name}.json")))
      current = JSON.parse(File.read(File.join(current_dir, "#{name}.json")))
      baseline_measurements = baseline.fetch("measurements").to_h { |item| [item.fetch("label"), item] }
      current_measurements = current.fetch("measurements").to_h { |item| [item.fetch("label"), item] }
      missing = baseline_measurements.keys - current_measurements.keys
      added = current_measurements.keys - baseline_measurements.keys
      unless missing.empty? && added.empty?
        abort("benchmark labels changed for #{name}: removed=#{missing.inspect}, added=#{added.inspect}")
      end

      current_measurements.each do |label, item|
        baseline_item = baseline_measurements.fetch(label)
        baseline_median = baseline_item.fetch("median_seconds", baseline_item.fetch("elapsed_seconds"))
        elapsed = item.fetch("median_seconds", item.fetch("elapsed_seconds"))
        allowed = baseline_median * threshold
        abort("benchmark regression: #{name} #{label} #{elapsed}s > #{allowed.round(6)}s") if elapsed > allowed
      end
    end
  end

  desc "Run WAV I/O benchmark"
  task :wav_io do
    run_benchmark_script("benchmarks/wav_io_benchmark.rb")
  end

  desc "Run DSP effects benchmark"
  task :dsp do
    run_benchmark_script("benchmarks/dsp_effects_benchmark.rb")
  end

  desc "Run FLAC encode/decode benchmark"
  task :flac do
    run_benchmark_script("benchmarks/flac_benchmark.rb")
  end

  desc "Run streaming memory benchmark"
  task :stream do
    run_benchmark_script("benchmarks/streaming_memory_benchmark.rb")
  end

  desc "Run all benchmarks"
  task all: %i[wav_io dsp flac stream]

  desc "Run all benchmarks and write JSON baseline reports"
  task :baseline do
    dir = benchmark_report_dir("baseline")
    run_benchmark_reports(dir)
    puts "benchmark baseline written to #{dir}"
  end

  desc "Run all benchmarks and compare with BENCH_BASELINE (default: tmp/benchmarks/baseline)"
  task :compare do
    baseline_dir = File.expand_path(ENV.fetch("BENCH_BASELINE", "tmp/benchmarks/baseline"), __dir__)
    current_dir = benchmark_report_dir("current")
    abort("missing benchmark baseline directory: #{baseline_dir}") unless Dir.exist?(baseline_dir)

    run_benchmark_reports(current_dir)
    compare_benchmark_reports!(baseline_dir, current_dir)
    puts "benchmark compare ok: #{current_dir} <= #{ENV.fetch('BENCH_THRESHOLD', '1.2')}x baseline"
  end
end

namespace :docs do
  def example_scripts
    %w[
      examples/format_convert.rb
      examples/synth_pad.rb
      examples/drum_machine.rb
      examples/audio_processing.rb
    ].freeze
  end

  def run_ruby_script(path)
    ruby = RbConfig.ruby
    success = system(ruby, File.expand_path(path, __dir__))
    abort("script failed: #{path}") unless success
  end

  desc "Generate YARD docs into doc/"
  task :yard do
    ruby = RbConfig.ruby
    success = system(ruby, "-S", "bundle", "exec", "yard", "doc")
    abort("yard doc failed") unless success
  end

  desc "Print YARD documentation coverage stats"
  task :stats do
    report = Wavify::Tools::YardCoverage.calculate
    puts format(
      "YARD objects: %<total>d (%<undocumented>d undocumented)\n%<percent>.2f%% documented",
      **report
    )
  end

  desc "Enforce minimum YARD documentation percentage (YARD_MINIMUM, default: 85)"
  task :check do
    minimum = ENV.fetch("YARD_MINIMUM", "85").to_f
    report = Wavify::Tools::YardCoverage.calculate
    percent = report.fetch(:percent)
    puts format("YARD objects: %<total>d (%<undocumented>d undocumented)", **report)
    abort("documentation coverage #{percent}% is below minimum #{minimum}%") if percent < minimum

    puts format("docs check ok: %.2f%% >= %.2f%%", percent, minimum)
  end

  desc "Smoke-run short example scripts (self-contained demo mode)"
  task :examples do
    example_scripts.each do |script|
      puts "== running #{script}"
      run_ruby_script(script)
    end
  end

  desc "Run docs-related checks and generators"
  task all: %i[examples yard check]
end

namespace :release do
  def load_release_spec!
    spec = Gem::Specification.load(File.expand_path("wavify.gemspec", __dir__))
    abort("failed to load wavify.gemspec") unless spec

    spec
  end

  def assert_release_check!(condition, message)
    return if condition

    abort("release check failed: #{message}")
  end

  desc "Validate gemspec metadata and packaged file list"
  task :check_gemspec do
    spec = load_release_spec!

    assert_release_check!(!spec.name.to_s.strip.empty?, "gemspec.name is empty")
    assert_release_check!(!spec.version.to_s.strip.empty?, "gemspec.version is empty")
    assert_release_check!(!spec.summary.to_s.strip.empty?, "gemspec.summary is empty")
    assert_release_check!(!spec.description.to_s.strip.empty?, "gemspec.description is empty")
    assert_release_check!(!spec.homepage.to_s.strip.empty?, "gemspec.homepage is empty")
    assert_release_check!(!spec.license.to_s.strip.empty?, "gemspec.license is empty")
    assert_release_check!(!spec.required_ruby_version.to_s.strip.empty?, "gemspec.required_ruby_version is empty")

    required_metadata_keys = %w[allowed_push_host homepage_uri source_code_uri changelog_uri rubygems_mfa_required]
    missing_metadata = required_metadata_keys.select { |key| spec.metadata[key].to_s.strip == "" }
    assert_release_check!(missing_metadata.empty?, "missing gemspec metadata keys: #{missing_metadata.join(', ')}")

    files = spec.files || []
    assert_release_check!(files.include?("lib/wavify.rb"), "gemspec.files does not include lib/wavify.rb")
    assert_release_check!(files.include?("README.md"), "gemspec.files does not include README.md")
    assert_release_check!(files.any? { |f| ["LICENSE", "LICENSE.txt"].include?(f) }, "gemspec.files does not include license file")
    assert_release_check!(files.none? { |f| f.start_with?(".idea/") }, ".idea files should not be packaged")
    assert_release_check!(files.none? { |f| f.start_with?("benchmarks/", "docs/", "tools/") }, "development utilities should not be packaged")

    puts "release check ok: gemspec metadata and package file list"
    puts "  name: #{spec.name}"
    puts "  version: #{spec.version}"
    puts "  packaged files: #{files.length}"
  end

  desc "Validate CHANGELOG structure and unreleased section"
  task :check_changelog do
    changelog_path = File.expand_path("CHANGELOG.md", __dir__)
    assert_release_check!(File.file?(changelog_path), "CHANGELOG.md is missing")

    changelog = File.read(changelog_path)
    assert_release_check!(changelog.include?("## [Unreleased]"), "CHANGELOG.md must include an [Unreleased] section")
    assert_release_check!(changelog.include?("Keep a Changelog"), "CHANGELOG.md should mention Keep a Changelog format")
    has_standard_subsection = changelog.match?(/^### (Added|Changed|Fixed|Removed|Security)$/)
    warn("release check warning: CHANGELOG.md has no standard subsection heading") unless has_standard_subsection

    puts "release check ok: CHANGELOG.md structure"
  end

  desc "Build gem package locally (same artifact as release flow)"
  task :build_package do
    Rake::Task["build"].reenable
    Rake::Task["build"].invoke
  end

  desc "Install the built gem into an isolated GEM_HOME and smoke-test require and CLI"
  task smoke_package: :build_package do
    spec = load_release_spec!
    package = File.expand_path("pkg/#{spec.file_name}", __dir__)
    assert_release_check!(File.file?(package), "built gem is missing: #{package}")

    Dir.mktmpdir("wavify-gem-smoke-") do |gem_home|
      bindir = File.join(gem_home, "bin")
      env = { "GEM_HOME" => gem_home, "GEM_PATH" => gem_home }
      ruby = RbConfig.ruby
      Bundler.with_unbundled_env do
        installed = system(
          env,
          ruby,
          "-S",
          "gem",
          "install",
          "--local",
          "--no-document",
          "--install-dir",
          gem_home,
          "--bindir",
          bindir,
          package
        )
        assert_release_check!(installed, "failed to install built gem")

        require_ok = system(env, ruby, "-e", 'require "wavify"; abort unless Wavify::VERSION')
        assert_release_check!(require_ok, 'installed gem failed to require "wavify"')

        executable = File.join(bindir, "wavify")
        assert_release_check!(File.file?(executable), "installed CLI executable is missing")
        assert_release_check!(system(env, ruby, executable, "--help", out: File::NULL), "installed CLI --help failed")
      end

      gem_root = File.join(gem_home, "gems", spec.full_name)
      %w[lib/wavify.rb sig/wavify.rbs README.md CHANGELOG.md LICENSE].each do |relative_path|
        assert_release_check!(File.file?(File.join(gem_root, relative_path)), "installed gem is missing #{relative_path}")
      end
    end

    puts "release check ok: isolated gem install, require, and CLI smoke test"
  end

  desc "Run release readiness checks (changelog, gemspec, build, install, require, CLI)"
  task check: %i[check_changelog check_gemspec smoke_package]
end
