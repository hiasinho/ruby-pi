# frozen_string_literal: true

require "json"
require "socket"
require "timeout"

class RawHttpServer
  STATUS_TEXT = {
    200 => "OK",
    400 => "Bad Request",
    401 => "Unauthorized",
    404 => "Not Found",
    500 => "Internal Server Error"
  }.freeze

  attr_reader :url

  def initialize(&handler)
    @handler = handler
    @requests = Queue.new
    @server = TCPServer.new("127.0.0.1", 0)
    @url = "http://127.0.0.1:#{@server.addr[1]}"
    @thread = Thread.new { run }
  end

  def pop_request(timeout: 2)
    Timeout.timeout(timeout) { @requests.pop }
  end

  def shutdown
    @server.close
    @thread.join(0.2)
  rescue IOError, Errno::EBADF
    nil
  end

  private

  def run
    loop do
      socket = @server.accept
      handle_connection(socket)
    end
  rescue IOError, Errno::EBADF
    nil
  end

  def handle_connection(socket)
    request_line = socket.gets("\r\n")
    return unless request_line

    method, path, version = request_line.strip.split(" ", 3)
    headers = read_headers(socket)
    body = read_body(socket, headers)
    request = {
      method: method,
      path: path,
      version: version,
      headers: headers,
      body: body,
      json: body.empty? ? nil : JSON.parse(body)
    }

    @requests << request
    @handler.call(socket, request)
  rescue JSON::ParserError => error
    @handler.call(socket, { error: error.message, raw_body: body })
  ensure
    socket.close unless socket.closed?
  end

  def read_headers(socket)
    headers = {}

    loop do
      line = socket.gets("\r\n")
      break if line.nil? || line == "\r\n"

      key, value = line.split(":", 2)
      headers[key.downcase] = value.to_s.strip
    end

    headers
  end

  def read_body(socket, headers)
    content_length = headers["content-length"].to_i
    return "" if content_length.zero?

    socket.read(content_length)
  end

  public

  def self.write_response(socket, status: 200, headers: {}, body: "")
    response_headers = {
      "Content-Length" => body.bytesize.to_s,
      "Connection" => "close"
    }.merge(headers)

    socket.write("HTTP/1.1 #{status} #{STATUS_TEXT.fetch(status, 'OK')}\r\n")
    response_headers.each do |key, value|
      socket.write("#{key}: #{value}\r\n")
    end
    socket.write("\r\n")
    socket.write(body)
    socket.flush
  end

  def self.write_chunked_response(socket, status: 200, headers: {}, chunks:, delay: nil)
    response_headers = {
      "Transfer-Encoding" => "chunked",
      "Connection" => "close"
    }.merge(headers)

    socket.write("HTTP/1.1 #{status} #{STATUS_TEXT.fetch(status, 'OK')}\r\n")
    response_headers.each do |key, value|
      socket.write("#{key}: #{value}\r\n")
    end
    socket.write("\r\n")

    Array(chunks).each do |chunk|
      sleep(delay) if delay
      socket.write("#{chunk.bytesize.to_s(16)}\r\n#{chunk}\r\n")
      socket.flush
    end

    socket.write("0\r\n\r\n")
    socket.flush
  rescue Errno::EPIPE, IOError
    nil
  end
end
