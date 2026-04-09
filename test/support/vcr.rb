# frozen_string_literal: true

require "fileutils"
require "yaml"

module RubyPi
  module TestSupport
    module Vcr
      CASSETTE_LIBRARY_DIR = File.expand_path("../fixtures/vcr_cassettes", __dir__)

      module_function

      def available?
        load!
      rescue LoadError
        false
      end

      def live_recording?
        ENV["LIVE_API"] == "1"
      end

      def cassette_path(name)
        File.join(CASSETTE_LIBRARY_DIR, "#{name}.yml")
      end

      def cassette_available?(name)
        File.exist?(cassette_path(name))
      end

      def ready?(cassette:, api_key_env: "OPENAI_API_KEY")
        return false unless available?

        cassette_available?(cassette) || (live_recording? && !ENV.fetch(api_key_env, "").empty?)
      end

      def use_cassette(name, **options, &block)
        load!
        WebMock.enable! if defined?(WebMock)
        ::VCR.use_cassette(name, default_options.merge(options), &block)
      end

      def unload!
        WebMock.disable! if defined?(WebMock)
      end

      def default_options
        {
          record: live_recording? ? :new_episodes : :none,
          match_requests_on: %i[method uri body]
        }
      end

      def latest_response_body(name)
        cassette = YAML.safe_load_file(cassette_path(name), permitted_classes: [ Time ], aliases: true) || {}
        interactions = Array(cassette["http_interactions"])
        interactions.reverse_each do |interaction|
          body = interaction.dig("response", "body", "string")
          return body if body && !body.empty?
        end

        nil
      end

      def load!
        return true if defined?(::VCR) && defined?(::WebMock)

        require "vcr"
        require "webmock/minitest"

        FileUtils.mkdir_p(CASSETTE_LIBRARY_DIR)

        ::VCR.configure do |config|
          config.cassette_library_dir = CASSETTE_LIBRARY_DIR
          config.hook_into :webmock
          config.ignore_localhost = true
          config.allow_http_connections_when_no_cassette = live_recording?
          config.default_cassette_options = default_options
          config.filter_sensitive_data("<OPENAI_API_KEY>") { ENV["OPENAI_API_KEY"] }
        end

        true
      end
    end
  end
end
