# frozen_string_literal: true

require_relative "ruby_pi/version"
require_relative "ruby_pi/messages"
require_relative "ruby_pi/cancellation"
require_relative "ruby_pi/stream"
require_relative "ruby_pi/schema_validator"
require_relative "ruby_pi/tool"
require_relative "ruby_pi/provider_registry"
require_relative "ruby_pi/model_registry"
require_relative "ruby_pi/http/client"
require_relative "ruby_pi/http/sse_parser"
require_relative "ruby_pi/auth"
require_relative "ruby_pi/providers"
require_relative "ruby_pi/models/defaults"
require_relative "ruby_pi/agent_loop"
require_relative "ruby_pi/agent"

module RubyPi
  class << self
    def providers
      @providers ||= ProviderRegistry.new
    end

    def models
      @models ||= ModelRegistry.new
    end

    def register_provider(api, adapter)
      providers.register(api, adapter)
    end

    def register_model(model)
      models.register(model)
    end

    def model(id:, provider:, api:, name: nil, base_url: nil, reasoning: false, input: [ "text" ], cost: nil, context_window: 0, max_tokens: 0, headers: nil, **extra)
      {
        id: id,
        name: name || id,
        provider: provider.to_s,
        api: api.to_sym,
        base_url: base_url,
        reasoning: reasoning,
        input: input,
        cost: cost || { input: 0, output: 0, cache_read: 0, cache_write: 0 },
        context_window: context_window,
        max_tokens: max_tokens,
        headers: headers
      }.merge(extra)
    end

    def build_agent(model:, system_prompt: "", tools: [], messages: [], **options)
      Agent.new(
        model: model,
        system_prompt: system_prompt,
        tools: tools,
        messages: messages,
        provider_registry: providers,
        **options
      )
    end

    def bootstrap!
      Providers.register_builtins(providers)
      Models::Defaults.register(models)
      self
    end
  end
end

RubyPi.bootstrap!
