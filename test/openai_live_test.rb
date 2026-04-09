# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/vcr"

class OpenAILiveTest < Minitest::Test
  CASSETTE = "openai/tool_call_double_21"

  def test_records_tool_call_stream_from_openai
    skip "install vcr to run recorded API tests" unless RubyPi::TestSupport::Vcr.available?
    skip missing_recording_message unless RubyPi::TestSupport::Vcr.ready?(cassette: CASSETTE)

    adapter = RubyPi::Providers::OpenAICompletions.new

    events = nil
    result = nil

    begin
      RubyPi::TestSupport::Vcr.use_cassette(CASSETTE) do
        stream = adapter.stream(
          model: openai_model,
          context: {
            system_prompt: "Use tools when a suitable tool exists. Return only tool calls when using a tool.",
            messages: [ RubyPi::Messages.user("Use the double tool for 21. Do not answer directly.") ],
            tools: [ double_tool_schema ]
          },
          options: {
            api_key: ENV["OPENAI_API_KEY"],
            max_tokens: 32
          },
          cancellation: RubyPi::Cancellation::Source.new.token
        )

        events = stream.to_a
        result = stream.result
      end
    ensure
      RubyPi::TestSupport::Vcr.unload!
    end

    tool_call = RubyPi::Messages.tool_calls(result).first

    assert_equal :tool_use, result[:stop_reason]
    refute_nil tool_call
    assert_equal "double", tool_call[:name]
    assert_equal({ "value" => 21 }, tool_call[:arguments])
    assert_includes events.map { |event| event[:type] }, :tool_call_start
    assert_includes events.map { |event| event[:type] }, :tool_call_end
    assert_includes RubyPi::TestSupport::Vcr.latest_response_body(CASSETTE), "[DONE]"
  end

  private

  def openai_model
    registry_id = ENV.fetch("OPENAI_MODEL", "openai/gpt-5.4-mini")
    RubyPi.models.fetch("openai", registry_id).merge(id: registry_id.split("/", 2).last)
  end

  def double_tool_schema
    {
      name: "double",
      description: "Double a number",
      parameters: {
        type: "object",
        properties: {
          value: { type: "integer" }
        },
        required: [ "value" ],
        additionalProperties: false
      }
    }
  end

  def missing_recording_message
    "set LIVE_API=1 and OPENAI_API_KEY to record #{RubyPi::TestSupport::Vcr.cassette_path(CASSETTE)}"
  end
end
