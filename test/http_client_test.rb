# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/raw_http_server"

class HttpClientTest < Minitest::Test
  def setup
    @client = RubyPi::Http::Client.new
  end

  def teardown
    @server&.shutdown
  end

  def test_post_sends_json_and_returns_response
    @server = RawHttpServer.new do |socket, request|
      assert_equal "POST", request[:method]
      assert_equal "/chat/completions", request[:path]
      assert_equal "application/json", request[:headers]["content-type"]
      assert_equal({ "hello" => "world" }, request[:json])

      RawHttpServer.write_response(
        socket,
        headers: { "Content-Type" => "application/json" },
        body: JSON.generate(ok: true)
      )
    end

    response = @client.post(
      url: "#{@server.url}/chat/completions",
      json: { hello: "world" },
      headers: { "X-Test" => "1" }
    )

    assert_equal 200, response[:status]
    assert_equal '{"ok":true}', response[:body]
  end

  def test_post_stream_yields_chunks
    chunks = []
    parser = RubyPi::Http::SseParser.new
    events = []
    @server = RawHttpServer.new do |socket, _request|
      RawHttpServer.write_chunked_response(
        socket,
        headers: { "Content-Type" => "text/event-stream" },
        chunks: ["data: {\"a\":1}\n\n", "data: [DONE]\n\n"]
      )
    end

    response = @client.post_stream(url: "#{@server.url}/chat/completions") do |chunk|
      chunks << chunk
      events.concat(parser.feed(chunk))
    end
    events.concat(parser.finish)

    assert_equal 200, response[:status]
    assert_operator chunks.length, :>=, 1
    assert_equal [{ type: :message, data: '{"a":1}', json: { a: 1 } }, { type: :done, data: "[DONE]" }], events
  end

  def test_post_stream_raises_when_cancelled_mid_stream
    source = RubyPi::Cancellation::Source.new
    seen_chunks = []
    @server = RawHttpServer.new do |socket, _request|
      socket.write("HTTP/1.1 200 OK\r\n")
      socket.write("Transfer-Encoding: chunked\r\n")
      socket.write("Content-Type: text/event-stream\r\n")
      socket.write("Connection: close\r\n")
      socket.write("\r\n")
      socket.write("5\r\nfirst\r\n")
      socket.flush

      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 1
      sleep 0.01 until source.cancelled? || Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
    rescue Errno::EPIPE, IOError
      nil
    end

    error = assert_raises(RubyPi::Cancellation::Cancelled) do
      @client.post_stream(
        url: "#{@server.url}/chat/completions",
        cancellation: source.token
      ) do |chunk|
        seen_chunks << chunk
        source.cancel("stop") if seen_chunks.length == 1
      end
    end

    assert_equal "stop", error.message
    assert_equal ["first"], seen_chunks
  end

  def test_post_stream_checks_cancellation_while_waiting_for_next_chunk
    source = RubyPi::Cancellation::Source.new
    @server = RawHttpServer.new do |socket, _request|
      RawHttpServer.write_chunked_response(
        socket,
        headers: { "Content-Type" => "text/event-stream" },
        chunks: ["late chunk"],
        delay: 0.5
      )
    end

    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    Thread.new do
      sleep 0.1
      source.cancel("quiet stream")
    end

    error = assert_raises(RubyPi::Cancellation::Cancelled) do
      @client.post_stream(
        url: "#{@server.url}/chat/completions",
        cancellation: source.token,
        timeout: 1
      ) { |_chunk| }
    end

    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
    assert_equal "quiet stream", error.message
    assert_operator elapsed, :<, 0.5
  end
end
