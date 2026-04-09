# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

module RubyPi
  module Http
    class Client
      DEFAULT_TIMEOUT = 120
      CANCELLATION_POLL_INTERVAL = 0.05
      CANCELLATION_SOCKET_ERRORS = [IOError, EOFError, Errno::EBADF, Errno::ECONNRESET, Errno::EPIPE, SocketError].freeze

      def post(url:, headers: {}, json: nil, body: nil, timeout: DEFAULT_TIMEOUT, cancellation: nil)
        request(url: url, headers: headers, json: json, body: body, timeout: timeout, cancellation: cancellation)
      end

      def post_stream(url:, headers: {}, json: nil, body: nil, timeout: DEFAULT_TIMEOUT, cancellation: nil, &block)
        request(url: url, headers: headers, json: json, body: body, timeout: timeout, cancellation: cancellation, &block)
      end

      private

      def request(url:, headers:, json:, body:, timeout:, cancellation:, &block)
        uri = URI(url)
        response_status = nil
        response_headers = nil
        response_body = +""
        streaming = block_given?

        Net::HTTP.start(
          uri.host,
          uri.port,
          use_ssl: uri.scheme == "https",
          open_timeout: timeout,
          read_timeout: timeout,
          write_timeout: timeout
        ) do |http|
          watcher = start_cancellation_watcher(http, cancellation, enabled: streaming)

          begin
            request = Net::HTTP::Post.new(uri)
            normalize_headers(headers).each do |key, value|
              request[key] = value
            end

            if json
              request["Content-Type"] ||= "application/json"
              request.body = JSON.generate(json)
            elsif body
              request.body = body
            end

            cancellation&.raise_if_cancelled!

            http.request(request) do |response|
              response_status = response.code.to_i
              response_headers = response.each_header.to_h
              read_response_body(response, response_body, cancellation, &block)
            end
          rescue *CANCELLATION_SOCKET_ERRORS, Net::ReadTimeout => error
            raise_cancelled_if_needed!(cancellation, error)
            raise
          ensure
            stop_cancellation_watcher(watcher)
          end
        end

        {
          status: response_status,
          headers: response_headers,
          body: response_body
        }
      end

      def read_response_body(response, response_body, cancellation)
        response.read_body do |chunk|
          cancellation&.raise_if_cancelled!
          response_body << chunk
          next unless block_given?

          yield chunk
          cancellation&.raise_if_cancelled!
        end
      rescue *CANCELLATION_SOCKET_ERRORS, Net::ReadTimeout => error
        raise_cancelled_if_needed!(cancellation, error)
        raise
      end

      def start_cancellation_watcher(http, cancellation, enabled:)
        return nil unless enabled && cancellation

        Thread.new do
          Thread.current.report_on_exception = false

          loop do
            break unless http.active?
            break unless cancellation

            if cancellation.cancelled?
              close_http_socket(http)
              break
            end

            sleep CANCELLATION_POLL_INTERVAL
          end
        end
      end

      def stop_cancellation_watcher(watcher)
        return unless watcher

        watcher.kill
        watcher.join
      end

      def close_http_socket(http)
        socket = http.instance_variable_get(:@socket)
        io = socket.respond_to?(:io) ? socket.io : socket
        io&.close
      rescue IOError, Errno::EBADF
        nil
      end

      def raise_cancelled_if_needed!(cancellation, original_error)
        return unless cancellation&.cancelled?

        raise RubyPi::Cancellation::Cancelled, (cancellation.reason || original_error.message)
      end

      def normalize_headers(headers)
        headers.each_with_object({}) do |(key, value), normalized|
          next if value.nil?

          normalized[key.to_s] = value.to_s
        end
      end
    end
  end
end
