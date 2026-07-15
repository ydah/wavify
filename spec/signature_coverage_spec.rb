# frozen_string_literal: true

require "yaml"

RSpec.describe "public RBS API parity" do
  manifest_path = File.expand_path("../sig/public_api.yml", __dir__)
  manifest = YAML.safe_load_file(manifest_path, permitted_classes: [], aliases: false)

  def constantize(name)
    name.split("::").reject(&:empty?).reduce(Object) { |namespace, part| namespace.const_get(part, false) }
  end

  manifest.each do |constant_name, contract|
    context constant_name do
      subject(:target) { constantize(constant_name) }

      let(:signature) do
        File.read(File.expand_path("../sig/#{contract.fetch('signature_file')}", __dir__))
      end

      Array(contract["class_methods"]).each do |method_name|
        it "implements and declares .#{method_name}" do
          expect(target).to respond_to(method_name)
          expect(signature).to match(/^\s*def self\.#{Regexp.escape(method_name)}:/)
        end
      end

      Array(contract["instance_methods"]).each do |method_name|
        it "implements and declares ##{method_name}" do
          expect(target.public_instance_methods).to include(method_name.to_sym)
          method_declaration = /^\s*def #{Regexp.escape(method_name)}:/
          attribute_declaration = /^\s*attr_(?:reader|accessor) #{Regexp.escape(method_name)}:/
          expect(signature).to match(method_declaration).or match(attribute_declaration)
        end
      end
    end
  end
end
