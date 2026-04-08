# frozen_string_literal: true

module RubyPi
  module MessageTransformer
    module_function

    def normalize_for_model(messages, model: nil)
      Array(messages).map do |message|
        transform_message(message, model: model)
      end
    end

    def transform_message(message, model: nil)
      copy = RubyPi::Messages.deep_copy(message)
      return copy unless copy[:role].to_sym == :assistant

      copy[:content] = Array(copy[:content]).filter_map do |part|
        case part[:type].to_sym
        when :thinking
          next if strip_thinking?(model)

          part
        when :tool_call
          part.merge(id: normalize_tool_call_id(part[:id]))
        else
          part
        end
      end

      copy
    end

    def normalize_tool_result(message)
      copy = RubyPi::Messages.deep_copy(message)
      return copy unless copy[:role].to_sym == :tool_result

      copy[:tool_call_id] = normalize_tool_call_id(copy[:tool_call_id])
      copy
    end

    def normalize_tool_call_id(id)
      id.to_s.gsub(/[^a-zA-Z0-9_-]/, "_")
    end

    def strip_thinking?(model)
      compat = model.is_a?(Hash) ? (model[:compat] || model["compat"] || {}) : {}
      !(compat[:preserve_reasoning] || compat["preserve_reasoning"])
    end
  end
end
