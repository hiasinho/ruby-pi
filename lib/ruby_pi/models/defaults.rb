# frozen_string_literal: true

module RubyPi
  module Models
    module Defaults
      module_function

      def all
        [
          RubyPi.model(
            id: "openai/gpt-4o-mini",
            name: "GPT-4o mini",
            provider: "openai",
            api: :openai_completions,
            base_url: "https://api.openai.com/v1",
            input: ["text", "image"],
            compat: {
              max_tokens_field: "max_tokens",
              supports_parallel_tool_calls: true,
              supports_reasoning_effort: false,
              supports_store: false,
              supports_developer_role: false
            }
          ),
          RubyPi.model(
            id: "openrouter/anthropic/claude-3.7-sonnet",
            name: "Claude 3.7 Sonnet via OpenRouter",
            provider: "openrouter",
            api: :openai_completions,
            base_url: "https://openrouter.ai/api/v1",
            input: ["text", "image"],
            compat: {
              max_tokens_field: "max_tokens",
              supports_parallel_tool_calls: true,
              supports_reasoning_effort: false,
              supports_store: false,
              supports_developer_role: false
            }
          ),
          RubyPi.model(
            id: "groq/llama-3.3-70b-versatile",
            name: "Llama 3.3 70B Versatile",
            provider: "groq",
            api: :openai_completions,
            base_url: "https://api.groq.com/openai/v1",
            input: ["text"],
            compat: {
              max_tokens_field: "max_tokens",
              supports_parallel_tool_calls: true,
              supports_reasoning_effort: false,
              supports_store: false,
              supports_developer_role: false
            }
          ),
          RubyPi.model(
            id: "local/openai-compatible",
            name: "Local OpenAI-compatible",
            provider: "local",
            api: :openai_completions,
            base_url: "http://localhost:11434/v1",
            input: ["text", "image"],
            compat: {
              max_tokens_field: "max_tokens",
              supports_parallel_tool_calls: true,
              supports_reasoning_effort: false,
              supports_store: false,
              supports_developer_role: false
            }
          )
        ]
      end

      def register(registry = RubyPi.models)
        all.each { |model| registry.register(model) }
        registry
      end
    end
  end
end
