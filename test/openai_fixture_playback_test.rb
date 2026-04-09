# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/raw_http_server"
require_relative "support/vcr"

class OpenAIFixturePlaybackTest < Minitest::Test
  CASSETTE = "openai/tool_call_double_21"

  def teardown
    @server&.shutdown
  end

  def test_replays_recorded_openai_stream_fixture
    skip "install vcr to run recorded API tests" unless RubyPi::TestSupport::Vcr.available?
    skip "record #{RubyPi::TestSupport::Vcr.cassette_path(CASSETTE)} with test/openai_live_test.rb first" unless RubyPi::TestSupport::Vcr.cassette_available?(CASSETTE)

    body = RubyPi::TestSupport::Vcr.latest_response_body(CASSETTE)
    @server = RawHttpServer.new do |socket, _request|
      RawHttpServer.write_chunked_response(
        socket,
        headers: { "Content-Type" => "text/event-stream" },
        chunks: body.bytes.each_slice(19).map { |bytes| bytes.pack("C*") }
      )
    end

    adapter = RubyPi::Providers::OpenAICompletions.new
    stream = adapter.stream(
      model: playback_model,
      context: {
        system_prompt: "Use tools when a suitable tool exists. Return only tool calls when using a tool.",
        messages: [RubyPi::Messages.user("Use the double tool for 21. Do not answer directly.")],
        tools: [double_tool_schema]
      },
      options: { api_key: "fixture" },
      cancellation: RubyPi::Cancellation::Source.new.token
    )

    events = stream.to_a
    result = stream.result
    tool_call = RubyPi::Messages.tool_calls(result).first

    assert_equal :tool_use, result[:stop_reason]
    assert_equal "double", tool_call[:name]
    assert_equal({ "value" => 21 }, tool_call[:arguments])
    assert_includes events.map { |event| event[:type] }, :tool_call_delta
    assert_includes events.map { |event| event[:type] }, :tool_call_end
  end

  private

  def playback_model
    RubyPi.models.fetch("openai", "openai/gpt-5.4-mini").merge(id: "gpt-5.4-mini", base_url: @server.url)
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
        required: ["value"],
        additionalProperties: false
      }
    }
  end
end
