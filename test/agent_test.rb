# frozen_string_literal: true

require_relative "test_helper"

class FakeProvider
  def stream(model:, context:, options:, cancellation:)
    stream = Rpi::Stream.new

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
      rescue Rpi::Cancellation::Cancelled => error
        aborted = Rpi::Messages.assistant(
          content: [Rpi::Messages.text("")],
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
    tool_call = Rpi::Messages.tool_call(id: "call-#{value}", name: "double", arguments: { "value" => value })
    assistant = Rpi::Messages.assistant(
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
    partial = Rpi::Messages.assistant(
      content: [Rpi::Messages.text("")],
      api: model[:api],
      provider: model[:provider],
      model: model[:id],
      stop_reason: :stop
    )
    final = Rpi::Messages.assistant(
      content: [Rpi::Messages.text(final_text)],
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
    final = Rpi::Messages.assistant(
      content: [Rpi::Messages.text(text)],
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
    @registry = Rpi::ProviderRegistry.new
    @registry.register(:fake, FakeProvider.new)
    @model = Rpi.model(id: "fake-1", provider: "spec", api: :fake)
  end

  def build_agent(tool: default_tool, **options)
    Rpi::Agent.new(
      model: @model,
      system_prompt: "You are helpful.",
      tools: [tool],
      provider_registry: @registry,
      **options
    )
  end

  def default_tool
    Rpi::Tool.define(
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
        content: [Rpi::Messages.text((arguments["value"] * 2).to_s)],
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
          content: [Rpi::Messages.text("override")],
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
