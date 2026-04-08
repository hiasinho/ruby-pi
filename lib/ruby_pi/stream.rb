# frozen_string_literal: true

require "thread"

module RubyPi
  class Stream
    include Enumerable

    SENTINEL = Object.new

    def initialize
      @queue = Queue.new
      @mutex = Mutex.new
      @condition = ConditionVariable.new
      @closed = false
      @result = nil
      @result_ready = false
    end

    def push(event)
      @mutex.synchronize do
        raise "stream closed" if @closed

        @queue << event
      end
      self
    end

    def close(result = nil)
      @mutex.synchronize do
        return self if @closed

        @closed = true
        @result = result
        @result_ready = true
        @queue << SENTINEL
        @condition.broadcast
      end
      self
    end

    def each
      return enum_for(:each) unless block_given?

      loop do
        item = @queue.pop
        break if item.equal?(SENTINEL)

        yield item
      end
    end

    def result
      @mutex.synchronize do
        @condition.wait(@mutex) until @result_ready
        @result
      end
    end
  end
end
