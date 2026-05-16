# frozen_string_literal: true

source "https://rubygems.org"

# Specify your gem's dependencies in wavify.gemspec
gemspec

gem "irb"
gem "benchmark", "~> 0.4"
gem "rake", "~> 13.0"
gem "rubocop", "~> 1.76", require: false
gem "rspec", "~> 3.0"
gem "simplecov", "~> 0.22", require: false
gem "yard", "~> 0.9", require: false

group :ogg do
  gem "ogg-ruby", ">= 0.1"
  gem "vorbis", ">= 0.1"
end

ruby_supports_rbs4 = Gem::Version.new(RUBY_VERSION) >= Gem::Version.new("3.2")

gem "rbs", "~> 4.0" if ruby_supports_rbs4
