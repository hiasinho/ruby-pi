# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/raw_http_server"

class OpenAICompletionsAdapterTest < Minitest::Test
  def teardown
    @server&.shutdown
  end

  def build_model(**extra)
    RubyPi.model(
      id: "test-model",
      provider: "openai",
      api: :openai_completions,
      base_url: @server.url,
      compat: {
        max_tokens_field: "max_tokens",
        supports_parallel_tool_calls: true,
        requires_tool_result_name: false
      }
    ).merge(extra)
  end

  def test_timeout_stays_local_and_whitelisted_stream_options_reach_payload
    http_client = Class.new do
      attr_reader :timeout, :json

      def post_stream(url:, headers:, json:, timeout:, cancellation:)
        @timeout = timeout
        @json = json
        yield "data: [DONE]\n\n"
        { status: 200, headers: {}, body: "" }
      end
    end.new

    model = RubyPi.model(
      id: "test-model",
      provider: "openai",
      api: :openai_completions,
      base_url: "http://example.test",
      compat: {
        max_tokens_field: "max_tokens",
        supports_parallel_tool_calls: true,
        requires_tool_result_name: false
      }
    )

    adapter = RubyPi::Providers::OpenAICompletions.new(http_client: http_client)
    stream = adapter.stream(
      model: model,
      context: {
        system_prompt: "",
        messages: [ RubyPi::Messages.user("Hi") ],
        tools: []
      },
      options: {
        api_key: "secret",
        stream_options: {
          timeout: 5,
          include_usage: true,
          ignored: "nope"
        }
      },
      cancellation: RubyPi::Cancellation::Source.new.token
    )

    stream.to_a
    stream.result

    assert_equal 5, http_client.timeout
    assert_equal({ include_usage: true }, http_client.json[:stream_options])
  end

  def test_plain_text_stream_normalizes_events_and_usage
    @server = RawHttpServer.new do |socket, _request|
      RawHttpServer.write_chunked_response(
        socket,
        headers: { "Content-Type" => "text/event-stream" },
        chunks: [
          "data: #{JSON.generate(id: 'resp-1', choices: [ { delta: { content: 'Hello ' }, finish_reason: nil } ])}\n\n",
          "data: #{JSON.generate(id: 'resp-1', choices: [ { delta: { content: 'world' }, finish_reason: 'stop' } ], usage: { prompt_tokens: 5, completion_tokens: 2, total_tokens: 7 })}\n\n",
          "data: [DONE]\n\n"
        ]
      )
    end

    adapter = RubyPi::Providers::OpenAICompletions.new
    stream = adapter.stream(
      model: build_model,
      context: {
        system_prompt: "You are helpful.",
        messages: [ RubyPi::Messages.user("Hi") ],
        tools: []
      },
      options: { api_key: "secret" },
      cancellation: RubyPi::Cancellation::Source.new.token
    )

    events = stream.to_a
    result = stream.result
    request = @server.pop_request

    assert_equal "Bearer secret", request[:headers]["authorization"]
    assert_equal "You are helpful.", request[:json]["messages"].first["content"]
    assert_equal "Hello world", result[:content].first[:text]
    assert_equal 5, result[:usage][:input]
    assert_equal 2, result[:usage][:output]
    assert_equal :start, events.first[:type]
    assert_includes events.map { |event| event[:type] }, :text_start
    assert_includes events.map { |event| event[:type] }, :text_delta
    assert_includes events.map { |event| event[:type] }, :text_end
    assert_equal :done, events.last[:type]
  end

  def test_tool_call_stream_accumulates_incremental_arguments
    @server = RawHttpServer.new do |socket, _request|
      RawHttpServer.write_chunked_response(
        socket,
        headers: { "Content-Type" => "text/event-stream" },
        chunks: [
          "data: #{JSON.generate(id: 'resp-2', choices: [ { delta: { tool_calls: [ { index: 0, id: 'call-1', function: { name: 'double', arguments: '{"value"' } } ] }, finish_reason: nil } ])}\n\n",
          "data: #{JSON.generate(id: 'resp-2', choices: [ { delta: { tool_calls: [ { index: 0, function: { arguments: ':21}' } } ] }, finish_reason: 'tool_calls' } ])}\n\n",
          "data: [DONE]\n\n"
        ]
      )
    end

    adapter = RubyPi::Providers::OpenAICompletions.new
    stream = adapter.stream(
      model: build_model,
      context: {
        system_prompt: "",
        messages: [ RubyPi::Messages.user("double 21") ],
        tools: [
          {
            name: "double",
            description: "Double a number",
            parameters: {
              type: "object",
              properties: {
                value: { type: "integer" }
              },
              required: [ "value" ]
            }
          }
        ]
      },
      options: { api_key: "secret" },
      cancellation: RubyPi::Cancellation::Source.new.token
    )

    events = stream.to_a
    result = stream.result

    tool_call = RubyPi::Messages.tool_calls(result).first
    assert_equal "double", tool_call[:name]
    assert_equal({ "value" => 21 }, tool_call[:arguments])
    assert_equal :tool_use, result[:stop_reason]
    assert_includes events.map { |event| event[:type] }, :tool_call_start
    assert_includes events.map { |event| event[:type] }, :tool_call_delta
    assert_includes events.map { |event| event[:type] }, :tool_call_end
  end

  def test_error_payload_becomes_error_result
    @server = RawHttpServer.new do |socket, _request|
      RawHttpServer.write_chunked_response(
        socket,
        status: 401,
        headers: { "Content-Type" => "text/event-stream" },
        chunks: [
          "data: #{JSON.generate(error: { message: 'bad key' })}\n\n"
        ]
      )
    end

    adapter = RubyPi::Providers::OpenAICompletions.new
    stream = adapter.stream(
      model: build_model,
      context: { system_prompt: "", messages: [ RubyPi::Messages.user("Hi") ], tools: [] },
      options: { api_key: "bad" },
      cancellation: RubyPi::Cancellation::Source.new.token
    )

    events = stream.to_a
    result = stream.result

    assert_equal :error, result[:stop_reason]
    assert_equal "bad key", result[:error_message]
    refute_includes events.map { |event| event[:type] }, :start
    assert_equal :error, events.last[:type]
  end

  def test_preserves_content_order_across_mixed_stream_parts
    @server = RawHttpServer.new do |socket, _request|
      RawHttpServer.write_chunked_response(
        socket,
        headers: { "Content-Type" => "text/event-stream" },
        chunks: [
          "data: #{JSON.generate(id: 'resp-4', choices: [ { delta: { tool_calls: [ { index: 0, id: 'call-1', function: { name: 'lookup', arguments: '{}' } } ] }, finish_reason: nil } ])}\n\n",
          "data: #{JSON.generate(id: 'resp-4', choices: [ { delta: { content: 'done' }, finish_reason: 'stop' } ])}\n\n",
          "data: [DONE]\n\n"
        ]
      )
    end

    adapter = RubyPi::Providers::OpenAICompletions.new
    stream = adapter.stream(
      model: build_model,
      context: { system_prompt: "", messages: [ RubyPi::Messages.user("Hi") ], tools: [] },
      options: { api_key: "secret" },
      cancellation: RubyPi::Cancellation::Source.new.token
    )

    events = stream.to_a
    result = stream.result

    assert_equal [ :tool_call, :text ], result[:content].map { |part| part[:type] }
    tool_start = events.find { |event| event[:type] == :tool_call_start }
    text_start = events.find { |event| event[:type] == :text_start }
    assert_equal 0, tool_start[:content_index]
    assert_equal 1, text_start[:content_index]
  end

  def test_cancellation_mid_stream_returns_aborted_message
    source = RubyPi::Cancellation::Source.new
    @server = RawHttpServer.new do |socket, _request|
      socket.write("HTTP/1.1 200 OK\r\n")
      socket.write("Transfer-Encoding: chunked\r\n")
      socket.write("Content-Type: text/event-stream\r\n")
      socket.write("Connection: close\r\n")
      socket.write("\r\n")

      first_event = "data: #{JSON.generate(id: 'resp-3', choices: [ { delta: { content: 'Hello' }, finish_reason: nil } ])}\n\n"
      socket.write("#{first_event.bytesize.to_s(16)}\r\n#{first_event}\r\n")
      socket.flush

      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 1
      sleep 0.01 until source.cancelled? || Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
    rescue Errno::EPIPE, IOError
      nil
    end

    adapter = RubyPi::Providers::OpenAICompletions.new
    stream = adapter.stream(
      model: build_model,
      context: { system_prompt: "", messages: [ RubyPi::Messages.user("Hi") ], tools: [] },
      options: { api_key: "secret" },
      cancellation: source.token
    )

    first_event = stream.each.first
    source.cancel("cancelled") if first_event
    stream.to_a
    result = stream.result

    assert_equal :aborted, result[:stop_reason]
    assert_equal "cancelled", result[:error_message]
  end
end

class OpenAICompletionsAgentIntegrationTest < Minitest::Test
  def setup
    @requests = Queue.new
    @server = RawHttpServer.new do |socket, request|
      @requests << request
      messages = request[:json]["messages"]
      last_message = messages.last

      if last_message["role"] == "user"
        value = last_message["content"].to_s[/double\s+(\d+)/, 1].to_i
        chunks = [
          "data: #{JSON.generate(id: 'resp-tool', choices: [ { delta: { tool_calls: [ { index: 0, id: "call-#{value}", function: { name: 'double', arguments: JSON.generate(value: value) } } ] }, finish_reason: 'tool_calls' } ])}\n\n",
          "data: [DONE]\n\n"
        ]
      else
        tool_result = last_message["content"]
        chunks = [
          "data: #{JSON.generate(id: 'resp-answer', choices: [ { delta: { content: "Result: #{tool_result}" }, finish_reason: 'stop' } ], usage: { prompt_tokens: 4, completion_tokens: 3, total_tokens: 7 })}\n\n",
          "data: [DONE]\n\n"
        ]
      end

      RawHttpServer.write_chunked_response(
        socket,
        headers: { "Content-Type" => "text/event-stream" },
        chunks: chunks
      )
    end

    @registry = RubyPi::ProviderRegistry.new
    @registry.register(:openai_completions, RubyPi::Providers::OpenAICompletions.new)
    @model = RubyPi.model(
      id: "test-model",
      provider: "openai",
      api: :openai_completions,
      base_url: @server.url,
      compat: {
        max_tokens_field: "max_tokens",
        supports_parallel_tool_calls: true,
        requires_tool_result_name: false
      }
    )
  end

  def teardown
    @server.shutdown
  end

  def test_agent_tool_loop_and_follow_up_work_with_adapter
    tool = RubyPi::Tool.define(
      name: "double",
      description: "Double a number",
      schema: {
        type: "object",
        properties: {
          value: { type: "integer" }
        },
        required: [ "value" ],
        additionalProperties: false
      }
    ) do |arguments, _cancellation|
      sleep 0.05
      {
        content: [ RubyPi::Messages.text((arguments["value"] * 2).to_s) ],
        details: {}
      }
    end

    agent = RubyPi::Agent.new(
      model: @model,
      system_prompt: "You are helpful.",
      tools: [ tool ],
      provider_registry: @registry,
      api_key: "secret"
    )

    agent.start("double 4")
    sleep 0.01
    agent.follow_up("double 5")
    agent.wait_until_idle

    assistant_texts = agent.messages.select do |message|
      message[:role] == :assistant && message[:content].first[:type] == :text
    end

    first_request = @requests.pop
    assert_equal "system", first_request[:json]["messages"].first["role"]
    assert_equal [ "Result: 8", "Result: 10" ], assistant_texts.map { |message| message[:content].first[:text] }
  end
end
