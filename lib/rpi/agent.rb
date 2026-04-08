# frozen_string_literal: true

require "set"
require "thread"

module Rpi
  class Agent
    class PendingMessageQueue
      attr_accessor :mode

      def initialize(mode)
        @mode = mode.to_sym
        @messages = []
        @mutex = Mutex.new
      end

      def enqueue(message)
        @mutex.synchronize { @messages << Messages.deep_copy(message) }
      end

      def has_items?
        @mutex.synchronize { @messages.any? }
      end

      def drain
        @mutex.synchronize do
          return [] if @messages.empty?

          if @mode == :all
            drained = @messages
            @messages = []
            drained
          else
            [@messages.shift]
          end
        end
      end

      def clear
        @mutex.synchronize { @messages = [] }
      end
    end

    attr_accessor :system_prompt,
                  :model,
                  :reasoning_level,
                  :tools,
                  :session_id,
                  :tool_execution,
                  :before_tool_call,
                  :after_tool_call,
                  :convert_to_llm,
                  :transform_context,
                  :get_api_key,
                  :api_key,
                  :stream,
                  :stream_options,
                  :metadata,
                  :provider_registry

    attr_reader :messages, :streaming_message, :pending_tool_calls, :last_error

    def initialize(model:, system_prompt: "", tools: [], messages: [], reasoning_level: nil, convert_to_llm: nil, transform_context: nil, get_api_key: nil, api_key: nil, before_tool_call: nil, after_tool_call: nil, tool_execution: :parallel, steering_mode: :one_at_a_time, follow_up_mode: :one_at_a_time, session_id: nil, stream: nil, stream_options: nil, metadata: nil, provider_registry: nil)
      @system_prompt = system_prompt.to_s
      @model = model
      @tools = Array(tools)
      @messages = Array(messages).map { |message| Messages.deep_copy(message) }
      @reasoning_level = reasoning_level
      @convert_to_llm = convert_to_llm || method(:default_convert_to_llm)
      @transform_context = transform_context
      @get_api_key = get_api_key
      @api_key = api_key
      @before_tool_call = before_tool_call
      @after_tool_call = after_tool_call
      @tool_execution = tool_execution.to_sym
      @session_id = session_id
      @stream = stream
      @stream_options = stream_options
      @metadata = metadata
      @provider_registry = provider_registry || Rpi.providers
      @streaming_message = nil
      @pending_tool_calls = Set.new
      @last_error = nil
      @listeners = []
      @state_mutex = Mutex.new
      @event_mutex = Mutex.new
      @steering_queue = PendingMessageQueue.new(steering_mode)
      @follow_up_queue = PendingMessageQueue.new(follow_up_mode)
      @active_run = nil
    end

    def subscribe(listener = nil, &block)
      callback = listener || block
      raise ArgumentError, "listener is required" unless callback

      @state_mutex.synchronize { @listeners << callback }
      -> { @state_mutex.synchronize { @listeners.delete(callback) } }
    end

    def steering_mode=(mode)
      @steering_queue.mode = mode
    end

    def steering_mode
      @steering_queue.mode
    end

    def follow_up_mode=(mode)
      @follow_up_queue.mode = mode
    end

    def follow_up_mode
      @follow_up_queue.mode
    end

    def busy?
      @state_mutex.synchronize { !@active_run.nil? }
    end

    def cancellation_token
      @state_mutex.synchronize { @active_run&.dig(:token) }
    end

    def steer(input, images: [])
      normalize_prompt_input(input, images: images).each do |message|
        @steering_queue.enqueue(message)
      end
      self
    end

    def follow_up(input, images: [])
      normalize_prompt_input(input, images: images).each do |message|
        @follow_up_queue.enqueue(message)
      end
      self
    end

    def clear_steering_queue
      @steering_queue.clear
    end

    def clear_follow_up_queue
      @follow_up_queue.clear
    end

    def clear_all_queues
      clear_steering_queue
      clear_follow_up_queue
    end

    def has_queued_messages?
      @steering_queue.has_items? || @follow_up_queue.has_items?
    end

    def cancel(reason = nil)
      @state_mutex.synchronize do
        @active_run&.dig(:source)&.cancel(reason)
      end
      self
    end

    def wait_until_idle
      thread = @state_mutex.synchronize { @active_run&.dig(:thread) }
      thread&.join
      nil
    end

    def reset!
      cancel("reset") if busy?
      wait_until_idle

      @state_mutex.synchronize do
        @messages = []
        @streaming_message = nil
        @pending_tool_calls = Set.new
        @last_error = nil
      end
      clear_all_queues
      self
    end

    def start(input, images: [])
      run_messages = normalize_prompt_input(input, images: images)
      start_run(kind: :prompt, messages: run_messages)
    end

    def prompt(input, images: [])
      start(input, images: images)
      wait_until_idle
    end

    def continue_async
      @state_mutex.synchronize do
        raise "Agent is already processing." if @active_run
      end

      last_message = @state_mutex.synchronize { @messages.last && Messages.deep_copy(@messages.last) }
      raise "No messages to continue from" unless last_message

      if last_message[:role].to_sym == :assistant
        queued_steering = @steering_queue.drain
        return start_run(kind: :prompt, messages: queued_steering, skip_initial_steering_poll: true) if queued_steering.any?

        queued_follow_ups = @follow_up_queue.drain
        return start_run(kind: :prompt, messages: queued_follow_ups) if queued_follow_ups.any?

        raise "Cannot continue from message role: assistant"
      end

      start_run(kind: :continue)
    end

    def continue
      continue_async
      wait_until_idle
    end

    private

    def start_run(kind:, messages: nil, skip_initial_steering_poll: false)
      @state_mutex.synchronize do
        raise "Agent is already processing." if @active_run

        source = Cancellation::Source.new
        token = source.token
        @streaming_message = nil
        @pending_tool_calls = Set.new
        @last_error = nil

        thread = Thread.new do
          begin
            if kind == :prompt
              AgentLoop.run(
                prompts: messages,
                context: create_context_snapshot,
                config: create_loop_config(skip_initial_steering_poll: skip_initial_steering_poll),
                cancellation: token,
                emitter: method(:process_event)
              )
            else
              AgentLoop.continue(
                context: create_context_snapshot,
                config: create_loop_config,
                cancellation: token,
                emitter: method(:process_event)
              )
            end
          rescue StandardError => error
            handle_run_failure(error, token)
          ensure
            finish_run
          end
        end

        @active_run = { source: source, token: token, thread: thread }
        thread
      end
    end

    def create_context_snapshot
      @state_mutex.synchronize do
        {
          system_prompt: @system_prompt,
          messages: @messages.map { |message| Messages.deep_copy(message) },
          tools: @tools.dup
        }
      end
    end

    def create_loop_config(skip_initial_steering_poll: false)
      steering_skip = skip_initial_steering_poll
      {
        model: @model,
        reasoning: @reasoning_level,
        session_id: @session_id,
        tool_execution: @tool_execution,
        before_tool_call: @before_tool_call,
        after_tool_call: @after_tool_call,
        convert_to_llm: @convert_to_llm,
        transform_context: @transform_context,
        get_api_key: @get_api_key,
        api_key: @api_key,
        stream: @stream,
        stream_options: @stream_options,
        metadata: @metadata,
        provider_registry: @provider_registry,
        get_steering_messages: lambda {
          if steering_skip
            steering_skip = false
            []
          else
            @steering_queue.drain
          end
        },
        get_follow_up_messages: -> { @follow_up_queue.drain }
      }
    end

    def process_event(event)
      @event_mutex.synchronize do
        apply_event_to_state(event)
        token = @state_mutex.synchronize { @active_run&.dig(:token) }
        raise "Agent listener invoked outside active run" unless token

        listeners = @state_mutex.synchronize { @listeners.dup }
        listeners.each do |listener|
          listener.call(Messages.deep_copy(event), token)
        end
      end
    end

    def apply_event_to_state(event)
      @state_mutex.synchronize do
        case event[:type].to_sym
        when :message_start, :message_update
          @streaming_message = Messages.deep_copy(event[:message])
        when :message_end
          @streaming_message = nil
          @messages << Messages.deep_copy(event[:message])
        when :tool_execution_start
          @pending_tool_calls = @pending_tool_calls.dup.add(event[:tool_call_id])
        when :tool_execution_end
          pending = @pending_tool_calls.dup
          pending.delete(event[:tool_call_id])
          @pending_tool_calls = pending
        when :turn_end
          message = event[:message]
          if message[:role].to_sym == :assistant && message[:error_message]
            @last_error = message[:error_message]
          end
        when :agent_end
          @streaming_message = nil
        end
      end
    end

    def handle_run_failure(error, token)
      failure_message = Messages.assistant(
        content: [Messages.text("")],
        api: @model[:api],
        provider: @model[:provider],
        model: @model[:id],
        stop_reason: token.cancelled? ? :aborted : :error,
        error_message: error.message
      )

      @state_mutex.synchronize do
        @messages << Messages.deep_copy(failure_message)
        @last_error = failure_message[:error_message]
      end

      process_event(type: :agent_end, messages: [failure_message])
    end

    def finish_run
      @state_mutex.synchronize do
        @streaming_message = nil
        @pending_tool_calls = Set.new
        @active_run = nil
      end
    end

    def default_convert_to_llm(messages)
      messages.select do |message|
        [:user, :assistant, :tool_result].include?(message[:role].to_sym)
      end
    end

    def normalize_prompt_input(input, images: [])
      return input.map { |message| Messages.deep_copy(message) } if input.is_a?(Array)
      return [Messages.deep_copy(input)] if input.is_a?(Hash)

      content = [Messages.text(input.to_s)]
      Array(images).each { |image| content << Messages.deep_copy(image) }
      [Messages.user(content)]
    end
  end
end
