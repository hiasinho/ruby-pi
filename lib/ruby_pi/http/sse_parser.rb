# frozen_string_literal: true

require "json"

module RubyPi
  module Http
    class SseParser
      def initialize
        @buffer = +""
        reset_event
      end

      def feed(chunk)
        @buffer << chunk.to_s
        events = []

        while (newline_index = @buffer.index("\n"))
          line = @buffer.slice!(0, newline_index + 1)
          process_line(line.delete_suffix("\n").delete_suffix("\r"), events)
        end

        events
      end

      def finish
        events = []
        process_line(@buffer, events) unless @buffer.empty?
        @buffer = +""

        event = flush_event
        events << event if event
        events
      end

      private

      def process_line(line, events)
        if line.empty?
          event = flush_event
          events << event if event
          return
        end

        return if line.start_with?(":")

        field, value = line.split(":", 2)
        value = value ? value.sub(/\A /, "") : ""

        case field
        when "event"
          @event_name = value
        when "data"
          @data_lines << value
        end
      end

      def flush_event
        return nil if @data_lines.empty?

        data = @data_lines.join("\n")
        event_name = (@event_name || "message").to_sym
        reset_event

        return { type: :done, data: "[DONE]" } if data == "[DONE]"

        {
          type: event_name,
          data: data,
          json: JSON.parse(data, symbolize_names: true)
        }
      end

      def reset_event
        @event_name = nil
        @data_lines = []
      end
    end
  end
end
