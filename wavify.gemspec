# frozen_string_literal: true

require_relative "lib/wavify/version"

Gem::Specification.new do |spec|
  spec.name = "wavify"
  spec.version = Wavify::VERSION
  spec.authors = ["Yudai Takada"]
  spec.email = ["t.yudai92@gmail.com"]

  spec.summary = "Pure Ruby audio processing toolkit with immutable transforms."
  spec.description = "Wavify provides ergonomic Ruby APIs for audio buffers, codec I/O, streaming pipelines, DSP effects, and a small sequencing DSL."
  spec.homepage = "https://github.com/ydah/wavify"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.1"

  spec.metadata["allowed_push_host"] = "https://rubygems.org"
  spec.metadata["homepage_uri"] = spec.homepage
  release_ref = "v#{spec.version}"
  spec.metadata["source_code_uri"] = "#{spec.homepage}/tree/#{release_ref}"
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/#{release_ref}/CHANGELOG.md"
  spec.metadata["rubygems_mfa_required"] = "true"

  package_patterns = [
    "lib/**/*",
    "exe/*",
    "sig/**/*",
    "CHANGELOG.md",
    "LICENSE",
    "README.md"
  ].freeze
  spec.files = Dir.chdir(__dir__) do
    package_patterns.flat_map { |pattern| Dir.glob(pattern, File::FNM_DOTMATCH) }
                    .select { |path| File.file?(path) }
                    .uniq
                    .sort
  end
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]
end
