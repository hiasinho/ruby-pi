# frozen_string_literal: true

module Rpi
  module Messages
    ZERO_USAGE = {
      input: 0,
      output: 0,
      cache_read: 0,
      cache_write: 0,
      total_tokens: 0,
      cost: {
        input: 0,
        output: 0,
        cache_read: 0,
        cache_write: 0,
        total: 0
      }
    }.freeze

    module_function

    def now_ms
      Process.clock_gettime(Process::CLOCK_REALTIME, :millisecond)
    end

    def deep_copy(object)
      case object
      when Hash
        object.each_with_object({}) { |(key, value), copy| copy[key] = deep_copy(value) }
      when Array
        object.map { |value| deep_copy(value) }
      when String
        object.dup
      else
        object
      end
    end

    def text(text)
      { type: :text, text: text.to_s }
    end

    def image(data:, mime_type:)
      { type: :image, data: data, mime_type: mime_type }
    end

    def thinking(thinking)
      { type: :thinking, thinking: thinking.to_s }
    end

    def tool_call(id:, name:, arguments:, thought_signature: nil)
      part = {
        type: :tool_call,
        id: id.to_s,
        name: name.to_s,
        arguments: deep_copy(arguments)
      }
      part[:thought_signature] = thought_signature if thought_signature
      part
    end

    def normalize_user_content(content)
      case content
      when String
        [text(content)]
      when Array
        content.map { |item| item.is_a?(String) ? text(item) : deep_copy(item) }
      else
        [deep_copy(content)]
      end
    end

    def user(content, timestamp: now_ms)
      {
        role: :user,
        content: normalize_user_content(content),
        timestamp: timestamp
      }
    end

    def assistant(content:, api:, provider:, model:, usage: nil, stop_reason:, error_message: nil, response_id: nil, timestamp: now_ms)
      message = {
        role: :assistant,
        content: deep_copy(content),
        api: api&.to_sym,
        provider: provider&.to_s,
        model: model&.to_s,
        usage: deep_copy(usage || ZERO_USAGE),
        stop_reason: stop_reason.to_sym,
        timestamp: timestamp
      }
      message[:error_message] = error_message if error_message
      message[:response_id] = response_id if response_id
      message
    end

    def tool_result(tool_call_id:, tool_name:, content:, is_error:, details: nil, timestamp: now_ms)
      {
        role: :tool_result,
        tool_call_id: tool_call_id.to_s,
        tool_name: tool_name.to_s,
        content: normalize_user_content(content),
        details: deep_copy(details),
        is_error: !!is_error,
        timestamp: timestamp
      }
    end

    def tool_calls(message)
      Array(message[:content]).select { |part| part[:type].to_sym == :tool_call }
    end

    def assistant_message?(message)
      message[:role].to_sym == :assistant
    end
  end
end
