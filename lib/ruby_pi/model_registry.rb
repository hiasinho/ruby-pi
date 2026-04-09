# frozen_string_literal: true

require "thread"

module RubyPi
  class ModelRegistry
    def initialize
      @mutex = Mutex.new
      @models = {}
    end

    def register(model)
      normalized = normalize_model(model)
      key = [ normalized[:provider].to_s, normalized[:id].to_s ]
      @mutex.synchronize { @models[key] = normalized }
      normalized
    end

    def fetch(provider, id)
      @mutex.synchronize do
        @models.fetch([ provider.to_s, id.to_s ]) do
          raise KeyError, "No model registered for provider=#{provider} id=#{id}"
        end
      end
    end

    def list(provider: nil)
      @mutex.synchronize do
        values = @models.values
        values = values.select { |model| model[:provider].to_s == provider.to_s } if provider
        values.map(&:dup)
      end
    end

    private

    def normalize_model(model)
      raise ArgumentError, "model must include :id, :provider, and :api" unless model[:id] && model[:provider] && model[:api]

      model.dup.tap do |copy|
        copy[:provider] = copy[:provider].to_s
        copy[:api] = copy[:api].to_sym
        copy[:headers] = Messages.deep_copy(copy[:headers]) if copy.key?(:headers)
        copy[:compat] = symbolize_keys(Messages.deep_copy(copy[:compat] || {}))
      end
    end

    def symbolize_keys(object)
      case object
      when Hash
        object.each_with_object({}) do |(key, value), copy|
          copy[key.respond_to?(:to_sym) ? key.to_sym : key] = symbolize_keys(value)
        end
      when Array
        object.map { |value| symbolize_keys(value) }
      else
        object
      end
    end
  end
end
