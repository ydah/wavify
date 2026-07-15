# frozen_string_literal: true

SimpleCov.configure do
  branch_coverage = ENV["SIMPLECOV_BRANCH"] == "1"
  enable_coverage :branch if branch_coverage

  add_filter "/spec/"
  add_filter "/examples/"
  add_filter "/benchmarks/"
  add_filter "/tmp/"

  add_group "Core", "lib/wavify/core"
  add_group "Codecs", "lib/wavify/codecs"
  add_group "DSP", "lib/wavify/dsp"
  add_group "Sequencer", "lib/wavify/sequencer"

  line_minimum = ENV.fetch("COVERAGE_MINIMUM", nil)
  branch_minimum = ENV.fetch("COVERAGE_BRANCH_MINIMUM", nil)
  per_file_minimum = ENV.fetch("COVERAGE_MINIMUM_PER_FILE", nil)
  branch_per_file_minimum = ENV.fetch("COVERAGE_BRANCH_MINIMUM_PER_FILE", nil)

  overall_limits = {}
  overall_limits[:line] = line_minimum.to_f if line_minimum && !line_minimum.empty?
  if branch_coverage && branch_minimum && !branch_minimum.empty?
    overall_limits[:branch] = branch_minimum.to_f
  end
  minimum_coverage(overall_limits) unless overall_limits.empty?

  per_file_limits = {}
  per_file_limits[:line] = per_file_minimum.to_f if per_file_minimum && !per_file_minimum.empty?
  if branch_coverage && branch_per_file_minimum && !branch_per_file_minimum.empty?
    per_file_limits[:branch] = branch_per_file_minimum.to_f
  end
  minimum_coverage_by_file(per_file_limits) unless per_file_limits.empty?
end
