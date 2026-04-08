# frozen_string_literal: true

require "thread"

module RubyPi
  class ProviderRegistry
    def initialize
      @mutex = Mutex.new
      @providers = {}
    end

    def register(api, adapter)
      @mutex.synchronize do
        @providers[api.to_sym] = adapter
      end
      adapter
    end

    def fetch(api)
      @mutex.synchronize do
        @providers.fetch(api.to_sym) do
          raise KeyError, "No provider registered for api: #{api}"
        end
      end
    end

    def registered?(api)
      @mutex.synchronize { @providers.key?(api.to_sym) }
    end

    def list
      @mutex.synchronize { @providers.dup }
    end
  end
end
