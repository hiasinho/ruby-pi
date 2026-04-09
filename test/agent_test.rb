# frozen_string_literal: true

require_relative "test_helper"

class FakeProvider
  def stream(model:, context:, options:, cancellation:)
    stream = RubyPi::Stream.new

    Thread.new do
      begin
        cancellation.raise_if_cancelled!
        last_message = context[:messages].last

        case last_message[:role]
        when :user
          emit_tool_request(stream, model, last_message)
        when :tool_result
          emit_final_answer(stream, model, last_message)
        else
          emit_plain_answer(stream, model, "done")
        end
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
      end
    end

    stream
  end

  private

  def emit_tool_request(stream, model, user_message)
    text = user_message[:content].map { |part| part[:text] }.join(" ")
    value = text[/double\s+(\d+)/, 1].to_i
    tool_call = RubyPi::Messages.tool_call(id: "call-#{value}", name: "double", arguments: { "value" => value })
    assistant = RubyPi::Messages.assistant(
      content: [tool_call],
      api: model[:api],
      provider: model[:provider],
      model: model[:id],
      stop_reason: :tool_use
    )

    stream.push(type: :start, partial: assistant)
    stream.push(type: :tool_call_start, content_index: 0, partial: assistant)
    stream.push(type: :tool_call_end, content_index: 0, tool_call: tool_call, partial: assistant)
    stream.push(type: :done, reason: :tool_use, message: assistant)
    stream.close(assistant)
  end

  def emit_final_answer(stream, model, tool_result)
    final_text = "Result: #{tool_result[:content].first[:text]}"
    partial = RubyPi::Messages.assistant(
      content: [RubyPi::Messages.text("")],
      api: model[:api],
      provider: model[:provider],
      model: model[:id],
      stop_reason: :stop
    )
    final = RubyPi::Messages.assistant(
      content: [RubyPi::Messages.text(final_text)],
      api: model[:api],
      provider: model[:provider],
      model: model[:id],
      stop_reason: :stop
    )

    stream.push(type: :start, partial: partial)
    stream.push(type: :text_delta, content_index: 0, delta: final_text, partial: final)
    stream.push(type: :done, reason: :stop, message: final)
    stream.close(final)
  end

  def emit_plain_answer(stream, model, text)
    final = RubyPi::Messages.assistant(
      content: [RubyPi::Messages.text(text)],
      api: model[:api],
      provider: model[:provider],
      model: model[:id],
      stop_reason: :stop
    )

    stream.push(type: :start, partial: final)
    stream.push(type: :done, reason: :stop, message: final)
    stream.close(final)
  end
end

class AgentTest < Minitest::Test
  def setup
    @registry = RubyPi::ProviderRegistry.new
    @registry.register(:fake, FakeProvider.new)
    @model = RubyPi.model(id: "fake-1", provider: "spec", api: :fake)
  end

  def build_agent(tool: default_tool, **options)
    RubyPi::Agent.new(
      model: @model,
      system_prompt: "You are helpful.",
      tools: [tool],
      provider_registry: @registry,
      **options
    )
  end

  def default_tool
    RubyPi::Tool.define(
      name: "double",
      description: "Double a number",
      schema: {
        type: "object",
        properties: {
          value: { type: "integer" }
        },
        required: ["value"],
        additionalProperties: false
      }
    ) do |arguments, _cancellation|
      sleep 0.05
      {
        content: [RubyPi::Messages.text((arguments["value"] * 2).to_s)],
        details: { doubled: arguments["value"] * 2 }
      }
    end
  end

  def test_prompt_runs_tool_loop_to_completion
    agent = build_agent
    events = []
    agent.subscribe { |event, _token| events << event[:type] }

    agent.prompt("double 21")

    assert_equal false, agent.busy?
    assert_nil agent.last_error
    assert_equal [:user, :assistant, :tool_result, :assistant], agent.messages.map { |message| message[:role] }
    assert_equal "Result: 42", agent.messages.last[:content].first[:text]
    assert_includes events, :tool_execution_start
    assert_includes events, :tool_execution_end
    assert_includes events, :agent_end
  end

  def test_start_and_follow_up_keep_loop_operational
    agent = build_agent

    agent.start("double 4")
    sleep 0.01
    assert_equal true, agent.busy?

    agent.follow_up("double 5")
    agent.wait_until_idle

    assistant_texts = agent.messages.select { |message| message[:role] == :assistant && message[:content].first[:type] == :text }
    assert_equal ["Result: 8", "Result: 10"], assistant_texts.map { |message| message[:content].first[:text] }
  end

  def test_before_and_after_tool_hooks_are_applied
    agent = build_agent(
      before_tool_call: lambda { |context, _token|
        { block: true, reason: "blocked #{context[:tool_call][:name]}" } if context[:args]["value"] == 3
      },
      after_tool_call: lambda { |_context, _token|
        {
          content: [RubyPi::Messages.text("override")],
          details: { overridden: true },
          is_error: false
        }
      }
    )

    agent.prompt("double 3")

    tool_result = agent.messages.find { |message| message[:role] == :tool_result }
    assert_equal true, tool_result[:is_error]
    assert_equal "blocked double", tool_result[:content].first[:text]

    agent.reset!
    agent.before_tool_call = nil
    agent.prompt("double 2")

    tool_result = agent.messages.find { |message| message[:role] == :tool_result }
    assert_equal false, tool_result[:is_error]
    assert_equal "override", tool_result[:content].first[:text]
    assert_equal({ overridden: true }, tool_result[:details])
  end

  def test_tool_result_normalizes_hash_content_and_details
    tool = RubyPi::Tool.define(name: "double", description: "Double a number") do |arguments, _cancellation|
      {
        content: (arguments["value"] * 2).to_s,
        details: { doubled: arguments["value"] * 2 }
      }
    end

    agent = build_agent(tool: tool)
    agent.prompt("double 2")

    tool_result = agent.messages.find { |message| message[:role] == :tool_result }
    assert_equal "4", tool_result[:content].first[:text]
    assert_equal({ doubled: 4 }, tool_result[:details])
    assert_equal "Result: 4", agent.messages.last[:content].first[:text]
  end

  def test_tool_result_normalizes_string_key_hash_and_defaults_details
    tool = RubyPi::Tool.define(name: "double", description: "Double a number") do |arguments, _cancellation|
      {
        "content" => (arguments["value"] * 2).to_s
      }
    end

    agent = build_agent(tool: tool)
    agent.prompt("double 3")

    tool_result = agent.messages.find { |message| message[:role] == :tool_result }
    assert_equal "6", tool_result[:content].first[:text]
    assert_equal({}, tool_result[:details])
    assert_equal "Result: 6", agent.messages.last[:content].first[:text]
  end

  def test_reset_cancels_and_clears_active_run
    agent = build_agent

    agent.start("double 9")
    sleep 0.01
    agent.reset!
    sleep 0.1

    assert_equal false, agent.busy?
    assert_empty agent.messages
    assert_nil agent.last_error
  end
end

class OrderedParallelProvider
  def stream(model:, context:, options:, cancellation:)
    stream = RubyPi::Stream.new

    Thread.new do
      cancellation.raise_if_cancelled!
      last_message = context[:messages].last

      if last_message[:role] == :user
        assistant = RubyPi::Messages.assistant(
          content: [
            RubyPi::Messages.tool_call(id: "call-1", name: "ok", arguments: {}),
            RubyPi::Messages.tool_call(id: "call-2", name: "missing", arguments: {})
          ],
          api: model[:api],
          provider: model[:provider],
          model: model[:id],
          stop_reason: :tool_use
        )
      else
        assistant = RubyPi::Messages.assistant(
          content: [RubyPi::Messages.text("done")],
          api: model[:api],
          provider: model[:provider],
          model: model[:id],
          stop_reason: :stop
        )
      end

      stream.push(type: :start, partial: assistant)
      stream.push(type: :done, message: assistant)
      stream.close(assistant)
    end

    stream
  end
end

class ToolTest < Minitest::Test
  def test_keyword_executor_accepts_subset_of_supported_keywords
    tool = RubyPi::Tool.define(name: "echo", description: "Echo args") do |arguments:|
      { content: [RubyPi::Messages.text(arguments["value"])], details: {} }
    end

    result = tool.call(
      tool_call_id: "call-1",
      arguments: { "value" => "ok" },
      cancellation: RubyPi::Cancellation::Source.new.token
    )

    assert_equal "ok", result[:content].first[:text]
  end
end

class SchemaValidatorTest < Minitest::Test
  def test_string_fields_do_not_coerce_hashes
    error = assert_raises(RubyPi::SchemaValidator::ValidationError) do
      RubyPi::SchemaValidator.validate!(
        {
          type: "object",
          properties: {
            query: { type: "string" }
          },
          required: ["query"],
          additionalProperties: false
        },
        { "query" => { "bad" => 1 } }
      )
    end

    assert_includes error.message, "$.query must be a string"
  end
end

class AgentParallelOrderingTest < Minitest::Test
  def test_parallel_tool_results_preserve_tool_call_order
    registry = RubyPi::ProviderRegistry.new
    registry.register(:fake, OrderedParallelProvider.new)
    model = RubyPi.model(id: "fake-1", provider: "spec", api: :fake)
    tool = RubyPi::Tool.define(name: "ok", description: "OK") do
      sleep 0.05
      { content: [RubyPi::Messages.text("ok")], details: {} }
    end

    agent = RubyPi::Agent.new(
      model: model,
      tools: [tool],
      provider_registry: registry
    )

    agent.prompt("run")

    tool_results = agent.messages.select { |message| message[:role] == :tool_result }
    assert_equal ["ok", "missing"], tool_results.map { |message| message[:tool_name] }
  end
end

class AgentLoopCallbackFailureTest < Minitest::Test
  def setup
    @model = RubyPi.model(id: "fake-1", provider: "spec", api: :fake)
  end

  def test_run_raises_when_steering_callback_fails
    error = assert_raises(RuntimeError) do
      RubyPi::AgentLoop.run(
        prompts: [RubyPi::Messages.user([RubyPi::Messages.text("hello")])],
        context: { system_prompt: "", messages: [], tools: [] },
        config: {
          model: @model,
          convert_to_llm: ->(messages) { messages },
          get_steering_messages: -> { raise "steering failed" }
        }
      )
    end

    assert_equal "steering failed", error.message
  end

  def test_run_raises_when_follow_up_callback_fails
    error = assert_raises(RuntimeError) do
      RubyPi::AgentLoop.run(
        prompts: [RubyPi::Messages.user([RubyPi::Messages.text("hello")])],
        context: { system_prompt: "", messages: [], tools: [] },
        config: {
          model: @model,
          convert_to_llm: ->(messages) { messages },
          stream: method(:plain_answer_stream),
          get_follow_up_messages: -> { raise "follow-up failed" }
        }
      )
    end

    assert_equal "follow-up failed", error.message
  end

  private

  def plain_answer_stream(model:, context:, options:, cancellation:)
    assistant = RubyPi::Messages.assistant(
      content: [RubyPi::Messages.text("done")],
      api: model[:api],
      provider: model[:provider],
      model: model[:id],
      stop_reason: :stop
    )

    RubyPi::Stream.new.tap do |stream|
      stream.push(type: :start, partial: assistant)
      stream.push(type: :done, message: assistant)
      stream.close(assistant)
    end
  end
end
