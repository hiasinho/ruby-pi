# frozen_string_literal: true

require_relative "lib/ruby_pi/version"

Gem::Specification.new do |spec|
  spec.name = "ruby_pi"
  spec.version = RubyPi::VERSION
  spec.authors = ["Mathias Maisberger"]
  spec.email = ["me@hiasinho.com"]

  spec.summary = "A small Ruby library for building tool-using LLM agents"
  spec.description = "RubyPi is a lightweight Ruby agent runtime with tools, streaming, provider and model registries, and an OpenAI-compatible adapter."
  spec.homepage = "https://github.com/hiasinho/ruby-pi"
  spec.license = "0BSD"
  spec.required_ruby_version = ">= 3.3"

  spec.metadata = {
    "documentation_uri" => "#{spec.homepage}/blob/main/README.md",
    "source_code_uri" => spec.homepage,
    "changelog_uri" => "#{spec.homepage}/blob/main/CHANGELOG.md",
    "bug_tracker_uri" => "#{spec.homepage}/issues",
    "rubygems_mfa_required" => "true"
  }

  spec.files = Dir.chdir(__dir__) do
    Dir[
      "CHANGELOG.md",
      "LICENSE",
      "README.md",
      "lib/**/*.rb"
    ]
  end

  spec.require_paths = ["lib"]

  spec.add_development_dependency "minitest"
  spec.add_development_dependency "vcr"
  spec.add_development_dependency "webmock"
end
