# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

module RubyPi
  module Http
    class Client
      DEFAULT_TIMEOUT = 120
      READ_POLL_INTERVAL = 0.1

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
          read_timeout: read_timeout_for(timeout, streaming: streaming, cancellation: cancellation),
          write_timeout: timeout
        ) do |http|
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
            read_response_body(response, response_body, timeout, cancellation, &block)
          end
        end

        {
          status: response_status,
          headers: response_headers,
          body: response_body
        }
      end

      def read_response_body(response, response_body, timeout, cancellation)
        last_activity_at = monotonic_now

        begin
          response.read_body do |chunk|
            cancellation&.raise_if_cancelled!
            last_activity_at = monotonic_now
            response_body << chunk
            yield chunk if block_given?
          end
        rescue Net::ReadTimeout
          cancellation&.raise_if_cancelled!
          raise if monotonic_now - last_activity_at >= timeout.to_f

          retry
        end
      end

      def read_timeout_for(timeout, streaming:, cancellation:)
        return timeout unless streaming && cancellation

        [timeout.to_f, READ_POLL_INTERVAL].min
      end

      def monotonic_now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
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
