# frozen_string_literal: true

require "thread"

module RubyPi
  module Cancellation
    class Cancelled < StandardError; end

    class Source
      def initialize
        @mutex = Mutex.new
        @cancelled = false
        @reason = nil
      end

      def token
        Token.new(self)
      end

      def cancel(reason = nil)
        @mutex.synchronize do
          @cancelled = true
          @reason = reason
        end
      end

      def cancelled?
        @mutex.synchronize { @cancelled }
      end

      def reason
        @mutex.synchronize { @reason }
      end
    end

    class Token
      def initialize(source)
        @source = source
      end

      def cancelled?
        @source.cancelled?
      end

      def reason
        @source.reason
      end

      def raise_if_cancelled!
        return unless cancelled?

        raise Cancelled, (reason || "cancelled")
      end
    end
  end
end
