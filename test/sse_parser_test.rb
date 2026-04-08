# frozen_string_literal: true

require_relative "test_helper"

class SseParserTest < Minitest::Test
  def setup
    @parser = RubyPi::Http::SseParser.new
  end

  def test_parses_basic_json_events
    events = @parser.feed("data: {\"ok\":true}\n\n")

    assert_equal 1, events.length
    assert_equal :message, events.first[:type]
    assert_equal({ ok: true }, events.first[:json])
  end

  def test_ignores_keepalive_lines
    events = @parser.feed(": ping\n\n")

    assert_empty events
  end

  def test_detects_done_event
    events = @parser.feed("data: [DONE]\n\n")

    assert_equal :done, events.first[:type]
  end

  def test_handles_split_chunks
    assert_empty @parser.feed("data: {\"step\":")

    events = @parser.feed("1}\n\n")

    assert_equal({ step: 1 }, events.first[:json])
  end

  def test_finish_flushes_last_event_without_trailing_blank_line
    assert_empty @parser.feed("data: {\"tail\":true}")

    events = @parser.finish

    assert_equal 1, events.length
    assert_equal({ tail: true }, events.first[:json])
  end
end
