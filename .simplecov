# frozen_string_literal: true

SimpleCov.configure do
  enable_coverage :branch if ENV["SIMPLECOV_BRANCH"] == "1"

  add_filter "/spec/"
  add_filter "/examples/"
  add_filter "/benchmarks/"
  add_filter "/tmp/"

  add_group "Core", "lib/wavify/core"
  add_group "Codecs", "lib/wavify/codecs"
  add_group "DSP", "lib/wavify/dsp"
  add_group "Sequencer", "lib/wavify/sequencer"

  minimum = ENV.fetch("COVERAGE_MINIMUM", nil)
  minimum_coverage(minimum.to_i) if minimum && !minimum.empty?
end
