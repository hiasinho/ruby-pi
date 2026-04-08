# frozen_string_literal: true

require_relative "providers/base"
require_relative "providers/openai_completions"

module RubyPi
  module Providers
    module_function

    def register_builtins(registry = RubyPi.providers)
      registry.register(:openai_completions, OpenAICompletions.new) unless registry.registered?(:openai_completions)
      registry
    end
  end
end
