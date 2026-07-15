# frozen_string_literal: true

require "stringio"
require "yard"
require "yard/cli/stats"

module Wavify
  module Tools
    # Computes YARD coverage through YARD's object registry instead of parsing
    # human-formatted command output.
    module YardCoverage
      module_function

      def calculate(files: ["lib/**/*.rb"])
        YARD::Registry.clear
        YARD.parse(files)
        stats = configured_stats(files)
        objects = stats.all_objects
        categories = coverage_categories(objects)
        total = categories.values.sum(&:length)
        undocumented = categories.values.sum { |items| items.count { |item| item.docstring.blank? } }
        documented = total - undocumented

        {
          total: total,
          documented: documented,
          undocumented: undocumented,
          percent: total.zero? ? 100.0 : (documented.fdiv(total) * 100.0)
        }.freeze
      ensure
        YARD::Registry.clear
      end

      def configured_stats(files)
        stats = YARD::CLI::Stats.new(false)
        logger = YARD::Logger.instance
        original_io = logger.io
        logger.io = StringIO.new
        stats.run(*files)
        stats
      ensure
        logger.io = original_io if logger && original_io
      end
      private_class_method :configured_stats

      def coverage_categories(objects)
        methods = objects.select { |object| object.type == :method }
        attributes = methods.select(&:is_attribute?).uniq { |method| method.name.to_s.delete_suffix("=") }
        ordinary_methods = methods.reject(&:is_alias?).reject(&:is_attribute?)
        {
          modules: objects.select { |object| object.type == :module },
          classes: objects.select { |object| object.type == :class },
          constants: objects.select { |object| object.type == :constant },
          attributes: attributes,
          methods: ordinary_methods
        }
      end
      private_class_method :coverage_categories
    end
  end
end
