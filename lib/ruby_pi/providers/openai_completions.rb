# frozen_string_literal: true

require "json"

module RubyPi
  module Providers
    class OpenAICompletions < Base
      def initialize(http_client: RubyPi::Http::Client.new)
        @http_client = http_client
      end

      def stream(model:, context:, options:, cancellation:)
        stream = RubyPi::Stream.new

        Thread.new do
          begin
            cancellation.raise_if_cancelled!

            state = initial_state
            parser = RubyPi::Http::SseParser.new

            response = @http_client.post_stream(
              url: endpoint_for(model),
              headers: build_headers(model, options),
              json: build_payload(model, context, options),
              timeout: request_timeout(options),
              cancellation: cancellation
            ) do |chunk|
              parser.feed(chunk).each do |event|
                next if event[:type] == :done

                process_event(event[:json], state, model, stream)
              end
            end

            parser.finish.each do |event|
              next if event[:type] == :done

              process_event(event[:json], state, model, stream)
            end

            raise error_message_for(response) if response[:status].to_i >= 400

            ensure_start_emitted(state, model, stream)
            finalize_open_content(state, model, stream)
            final_message = build_message(model, state, stop_reason: state[:stop_reason], response_id: state[:response_id])
            stream.push(type: final_event_type(final_message), reason: final_message[:stop_reason], message: final_message)
            stream.close(final_message)
          rescue RubyPi::Cancellation::Cancelled => error
            aborted = RubyPi::Messages.assistant(
              content: [RubyPi::Messages.text("")],
              api: model[:api],
              provider: model[:provider],
              model: model[:id],
              stop_reason: :aborted,
              error_message: error.message
            )
            stream.push(type: :error, reason: :aborted, error: aborted)
            stream.close(aborted)
          rescue StandardError => error
            failure = RubyPi::Messages.assistant(
              content: [RubyPi::Messages.text("")],
              api: model[:api],
              provider: model[:provider],
              model: model[:id],
              stop_reason: :error,
              error_message: error.message
            )
            stream.push(type: :error, reason: :error, error: failure)
            stream.close(failure)
          end
        end

        stream
      end

      def build_headers(model, options)
        headers = {
          "Accept" => "text/event-stream",
          "Content-Type" => "application/json"
        }

        merge_headers!(headers, model[:headers])
        merge_headers!(headers, options[:auth_headers])
        headers["Authorization"] = "Bearer #{options[:api_key]}" if options[:api_key]
        headers
      end

      def build_payload(model, context, options)
        compat = compat_for(model)
        payload = {
          model: model[:id],
          messages: convert_messages(context, compat),
          stream: true
        }

        tools = convert_tools(context[:tools])
        payload[:tools] = tools if tools.any?

        if compat.key?(:supports_parallel_tool_calls) && tools.any?
          payload[:parallel_tool_calls] = !!compat[:supports_parallel_tool_calls]
        end

        max_tokens = options[:max_tokens] || model[:max_tokens]
        max_tokens_field = (compat[:max_tokens_field] || "max_tokens").to_sym
        payload[max_tokens_field] = max_tokens if max_tokens.to_i.positive?

        payload[:store] = false if compat[:supports_store]

        if options[:reasoning]
          if compat[:supports_reasoning_effort]
            payload[:reasoning_effort] = options[:reasoning].to_s
          elsif compat[:thinking_format]
            payload[:reasoning] = { format: compat[:thinking_format], effort: options[:reasoning].to_s }
          end
        end

        payload[:metadata] = options[:metadata] if options[:metadata]
        payload[:user] = options[:session_id].to_s if options[:session_id]

        stream_options = payload_stream_options(options)
        payload[:stream_options] = stream_options if stream_options
        payload
      end

      def convert_messages(context, compat = {})
        messages = []
        system_prompt = context[:system_prompt].to_s
        if !system_prompt.empty?
          role = compat[:system_role] || (compat[:supports_developer_role] ? "developer" : "system")
          messages << { role: role, content: system_prompt }
        end

        Array(context[:messages]).each do |message|
          case message[:role].to_sym
          when :user
            messages << { role: "user", content: convert_user_content(message[:content]) }
          when :assistant
            converted = convert_assistant_message(message)
            messages << converted if converted
          when :tool_result
            messages << convert_tool_result(message, compat)
          end
        end

        messages
      end

      def convert_tools(tools)
        Array(tools).map do |tool|
          {
            type: "function",
            function: {
              name: tool[:name].to_s,
              description: tool[:description].to_s,
              parameters: tool[:parameters] || { type: "object" }
            }
          }
        end
      end

      def convert_tool_result(message, compat)
        converted = {
          role: "tool",
          tool_call_id: message[:tool_call_id].to_s,
          content: text_from_parts(message[:content])
        }
        converted[:name] = message[:tool_name].to_s if compat[:requires_tool_result_name]
        converted
      end

      def map_finish_reason(reason)
        case reason.to_s
        when "stop", "end_turn"
          :stop
        when "tool_calls", "function_call"
          :tool_use
        when "length", "max_tokens"
          :max_tokens
        when "content_filter"
          :content_filter
        when "error"
          :error
        else
          reason ? reason.to_s.tr("-", "_").to_sym : :stop
        end
      end

      def calculate_usage(raw_usage, _model)
        return RubyPi::Messages.deep_copy(RubyPi::Messages::ZERO_USAGE) unless raw_usage

        prompt_tokens = value_at(raw_usage, :prompt_tokens, :input_tokens).to_i
        completion_tokens = value_at(raw_usage, :completion_tokens, :output_tokens).to_i
        total_tokens = value_at(raw_usage, :total_tokens).to_i
        total_tokens = prompt_tokens + completion_tokens if total_tokens.zero?

        cache_read = value_at(raw_usage, :cache_read, :cached_tokens).to_i
        cache_write = value_at(raw_usage, :cache_write).to_i
        cost = value_at(raw_usage, :cost)

        {
          input: prompt_tokens,
          output: completion_tokens,
          cache_read: cache_read,
          cache_write: cache_write,
          total_tokens: total_tokens,
          cost: {
            input: value_at(cost, :input).to_f,
            output: value_at(cost, :output).to_f,
            cache_read: value_at(cost, :cache_read).to_f,
            cache_write: value_at(cost, :cache_write).to_f,
            total: value_at(cost, :total).to_f
          }
        }
      end

      private

      def initial_state
        {
          response_id: nil,
          usage: RubyPi::Messages.deep_copy(RubyPi::Messages::ZERO_USAGE),
          stop_reason: :stop,
          start_emitted: false,
          content_parts: {},
          content_order: []
        }
      end

      def process_event(payload, state, model, stream)
        if payload[:error]
          raise payload[:error][:message] || payload[:error].inspect
        end

        state[:response_id] ||= payload[:id] || payload[:response_id]
        state[:usage] = calculate_usage(payload[:usage], model) if payload[:usage]

        Array(payload[:choices]).each do |choice|
          delta = choice[:delta] || choice[:message] || {}
          handle_text_delta(delta, state, model, stream)
          handle_thinking_delta(delta, state, model, stream)
          handle_tool_call_delta(delta, state, model, stream)
          state[:stop_reason] = map_finish_reason(choice[:finish_reason]) if choice[:finish_reason]
        end
      end

      def handle_text_delta(delta, state, model, stream)
        text_delta = extract_text_delta(delta)
        return if text_delta.empty?

        key = :text
        part = ensure_text_part(state)

        unless part[:started]
          part[:started] = true
          ensure_start_emitted(state, model, stream)
          stream.push(type: :text_start, content_index: content_index(state, key), partial: build_message(model, state, stop_reason: :streaming))
        end

        part[:text] << text_delta
        stream.push(
          type: :text_delta,
          content_index: content_index(state, key),
          delta: text_delta,
          partial: build_message(model, state, stop_reason: :streaming)
        )
      end

      def handle_thinking_delta(delta, state, model, stream)
        thinking_delta = extract_thinking_delta(delta)
        return if thinking_delta.empty?

        key = :thinking
        part = ensure_thinking_part(state)

        unless part[:started]
          part[:started] = true
          ensure_start_emitted(state, model, stream)
          stream.push(type: :thinking_start, content_index: content_index(state, key), partial: build_message(model, state, stop_reason: :streaming))
        end

        part[:thinking] << thinking_delta
        stream.push(
          type: :thinking_delta,
          content_index: content_index(state, key),
          delta: thinking_delta,
          partial: build_message(model, state, stop_reason: :streaming)
        )
      end

      def handle_tool_call_delta(delta, state, model, stream)
        Array(delta[:tool_calls]).each do |tool_call_delta|
          index = (tool_call_delta[:index] || tool_call_count(state)).to_i
          key = [:tool_call, index]
          part = ensure_tool_call_part(state, index)
          function = tool_call_delta[:function] || {}

          part[:id] ||= tool_call_delta[:id] || "call_#{index}"
          part[:name] ||= function[:name] if function[:name]

          unless part[:started]
            part[:started] = true
            ensure_start_emitted(state, model, stream)
            stream.push(type: :tool_call_start, content_index: content_index(state, key), partial: build_message(model, state, stop_reason: :streaming))
          end

          delta_payload = {}
          delta_payload[:name] = function[:name] if function[:name]

          if function[:arguments]
            part[:arguments] << function[:arguments]
            delta_payload[:arguments] = function[:arguments]
          end

          next if delta_payload.empty?

          stream.push(
            type: :tool_call_delta,
            content_index: content_index(state, key),
            delta: delta_payload,
            partial: build_message(model, state, stop_reason: :streaming)
          )
        end
      end

      def ensure_start_emitted(state, model, stream)
        return if state[:start_emitted]

        state[:start_emitted] = true
        stream.push(type: :start, partial: build_message(model, state, stop_reason: :streaming))
      end

      def finalize_open_content(state, model, stream)
        state[:content_order].each do |key|
          part = state[:content_parts][key]

          case part[:type]
          when :text
            next if part[:closed]

            part[:closed] = true
            stream.push(
              type: :text_end,
              content_index: content_index(state, key),
              text: part[:text],
              partial: build_message(model, state, stop_reason: state[:stop_reason])
            )
          when :thinking
            next if part[:closed]

            part[:closed] = true
            stream.push(
              type: :thinking_end,
              content_index: content_index(state, key),
              thinking: part[:thinking],
              partial: build_message(model, state, stop_reason: state[:stop_reason])
            )
          when :tool_call
            next if part[:ended]

            part[:ended] = true
            stream.push(
              type: :tool_call_end,
              content_index: content_index(state, key),
              tool_call: normalized_tool_call(part),
              partial: build_message(model, state, stop_reason: state[:stop_reason])
            )
          end
        end
      end

      def build_message(model, state, stop_reason:, response_id: state[:response_id])
        content = state[:content_order].map do |key|
          normalize_content_part(state[:content_parts][key])
        end

        RubyPi::Messages.assistant(
          content: content,
          api: model[:api],
          provider: model[:provider],
          model: model[:id],
          usage: state[:usage],
          stop_reason: stop_reason,
          response_id: response_id
        )
      end

      def normalize_content_part(part)
        case part[:type]
        when :text
          RubyPi::Messages.text(part[:text])
        when :thinking
          RubyPi::Messages.thinking(part[:thinking])
        when :tool_call
          normalized_tool_call(part)
        end
      end

      def ensure_text_part(state)
        ensure_content_part(state, :text) do
          { type: :text, text: +"", started: false, closed: false }
        end
      end

      def ensure_thinking_part(state)
        ensure_content_part(state, :thinking) do
          { type: :thinking, thinking: +"", started: false, closed: false }
        end
      end

      def ensure_tool_call_part(state, index)
        ensure_content_part(state, [:tool_call, index]) do
          {
            type: :tool_call,
            index: index,
            id: nil,
            name: nil,
            arguments: +"",
            started: false,
            ended: false
          }
        end
      end

      def ensure_content_part(state, key)
        unless state[:content_parts].key?(key)
          state[:content_parts][key] = yield
          state[:content_order] << key
        end

        state[:content_parts][key]
      end

      def content_index(state, key)
        state[:content_order].index(key).to_i
      end

      def tool_call_count(state)
        state[:content_order].count { |key| key.is_a?(Array) && key.first == :tool_call }
      end

      def normalized_tool_call(part)
        RubyPi::Messages.tool_call(
          id: part[:id] || "",
          name: part[:name] || "",
          arguments: parse_arguments(part[:arguments])
        )
      end

      def parse_arguments(arguments)
        return {} if arguments.nil? || arguments.empty?

        JSON.parse(arguments)
      rescue JSON::ParserError
        arguments
      end

      def extract_text_delta(delta)
        content = delta[:content]
        return content if content.is_a?(String)

        Array(content).filter_map do |part|
          next part[:text] if part[:type].to_s == "text"
          next part.dig(:text, :value) if part[:text].is_a?(Hash)
        end.join
      end

      def extract_thinking_delta(delta)
        value = delta[:reasoning] || delta[:reasoning_content] || delta[:thinking]
        return value if value.is_a?(String)

        Array(value).filter_map do |part|
          part[:text] || part[:thinking] || part.dig(:text, :value)
        end.join
      end

      def compat_for(model)
        raw_compat = model[:compat] || {}
        raw_compat.each_with_object({}) do |(key, value), compat|
          compat[key.to_sym] = value
        end
      end

      def convert_user_content(content)
        parts = Array(content)
        mapped_parts = parts.filter_map do |part|
          case part[:type].to_sym
          when :text
            { type: "text", text: part[:text].to_s }
          when :image
            {
              type: "image_url",
              image_url: {
                url: "data:#{part[:mime_type]};base64,#{part[:data]}"
              }
            }
          end
        end

        return mapped_parts.map { |part| part[:text] }.join("\n") if mapped_parts.all? { |part| part[:type] == "text" }

        mapped_parts
      end

      def convert_assistant_message(message)
        text_parts = Array(message[:content]).select { |part| part[:type].to_sym == :text }
        tool_calls = Array(message[:content]).select { |part| part[:type].to_sym == :tool_call }
        return nil if text_parts.empty? && tool_calls.empty?

        converted = { role: "assistant" }
        converted[:content] = text_parts.map { |part| part[:text].to_s }.join("\n") if text_parts.any?
        converted[:content] = nil if tool_calls.any? && text_parts.empty?

        if tool_calls.any?
          converted[:tool_calls] = tool_calls.map do |tool_call|
            {
              id: tool_call[:id].to_s,
              type: "function",
              function: {
                name: tool_call[:name].to_s,
                arguments: tool_call[:arguments].is_a?(String) ? tool_call[:arguments] : JSON.generate(tool_call[:arguments])
              }
            }
          end
        end

        converted
      end

      def text_from_parts(parts)
        Array(parts).filter_map do |part|
          next part[:text].to_s if part[:type].to_sym == :text
          next JSON.generate(part) unless part[:type].to_sym == :thinking
        end.join("\n")
      end

      def endpoint_for(model)
        base_url = model[:endpoint] || model[:url] || model[:base_url]
        raise ArgumentError, "model must include :base_url" if base_url.to_s.empty?

        return base_url if base_url.end_with?("/chat/completions")

        "#{base_url.sub(%r{/+$}, "")}/chat/completions"
      end

      def request_timeout(options)
        stream_options = options[:stream_options]
        timeout = value_at(stream_options, :timeout)
        return timeout if timeout

        RubyPi::Http::Client::DEFAULT_TIMEOUT
      end

      def payload_stream_options(options)
        stream_options = options[:stream_options]
        return unless stream_options.is_a?(Hash)

        include_usage = value_at(stream_options, :include_usage)
        return if include_usage.nil?

        { include_usage: include_usage }
      end

      def merge_headers!(target, headers)
        return target unless headers.is_a?(Hash)

        headers.each do |key, value|
          next if value.nil?

          target[key.to_s] = value.to_s
        end

        target
      end

      def final_event_type(message)
        message[:stop_reason].to_sym == :error ? :error : :done
      end

      def error_message_for(response)
        body = response[:body].to_s
        return "HTTP #{response[:status]}" if body.empty?

        json = JSON.parse(body, symbolize_names: true)
        json.dig(:error, :message) || json[:message] || body
      rescue JSON::ParserError
        body
      end

      def value_at(hash, *keys)
        return nil unless hash.respond_to?(:[])

        keys.each do |key|
          value = hash[key]
          return value unless value.nil?

          value = hash[key.to_s]
          return value unless value.nil?
        end

        nil
      end
    end
  end
end
