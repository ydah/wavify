# frozen_string_literal: true

if ENV["COVERAGE"] == "1"
  begin
    require "simplecov"
  rescue LoadError => e
    abort("coverage requested (COVERAGE=1) but simplecov is unavailable: #{e.message}")
  end

  simplecov_profile = ENV.fetch("SIMPLECOV_PROFILE", "test_frameworks")
  if SimpleCov.respond_to?(:profiles) && SimpleCov.profiles.key?(simplecov_profile)
    SimpleCov.start(simplecov_profile.to_sym)
  else
    SimpleCov.start
  end
end

require "wavify"

RSpec.configure do |config|
  # Enable flags like --only-failures and --next-failure
  config.example_status_persistence_file_path = ".rspec_status"

  # Disable RSpec exposing methods globally on `Module` and `main`
  config.disable_monkey_patching!

  config.expect_with :rspec do |c|
    c.syntax = :expect
  end
end
