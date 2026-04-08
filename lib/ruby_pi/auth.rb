# frozen_string_literal: true

module RubyPi
  module Auth
    ENV_KEYS = {
      "openai" => "OPENAI_API_KEY",
      "openrouter" => "OPENROUTER_API_KEY",
      "groq" => "GROQ_API_KEY",
      "cerebras" => "CEREBRAS_API_KEY",
      "xai" => "XAI_API_KEY"
    }.freeze

    module_function

    def resolve(provider, api_key: nil, get_api_key: nil)
      resolved_headers = {}
      resolved_key = extract_api_key(api_key, resolved_headers)

      if resolved_key.nil? && get_api_key
        callback_value = get_api_key.call(provider)
        resolved_key = extract_api_key(callback_value, resolved_headers)
      end

      resolved_key ||= ENV[ENV_KEYS[provider.to_s]] if ENV_KEYS.key?(provider.to_s)

      {
        api_key: resolved_key,
        headers: resolved_headers
      }
    end

    def extract_api_key(value, resolved_headers)
      return value if value.is_a?(String)
      return nil unless value.is_a?(Hash)

      headers = value[:headers] || value["headers"]
      if headers.is_a?(Hash)
        headers.each do |key, header_value|
          resolved_headers[key.to_s] = header_value
        end
      end

      value[:api_key] || value["api_key"]
    end
    private_class_method :extract_api_key
  end
end
