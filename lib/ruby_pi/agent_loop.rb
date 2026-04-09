# frozen_string_literal: true

require "thread"

module RubyPi
  class AgentLoop
    UPDATE_EVENT_TYPES = [
      :text_start,
      :text_delta,
      :text_end,
      :thinking_start,
      :thinking_delta,
      :thinking_end,
      :tool_call_start,
      :tool_call_delta,
      :tool_call_end
    ].freeze

    class << self
      def run(prompts:, context:, config:, cancellation: nil, emitter: nil)
        loop = new(context: context, config: config, cancellation: cancellation, emitter: emitter)
        loop.run(prompts)
      end

      def continue(context:, config:, cancellation: nil, emitter: nil)
        loop = new(context: context, config: config, cancellation: cancellation, emitter: emitter)
        loop.continue
      end

      def stream(prompts:, context:, config:, cancellation: nil)
        stream = Stream.new
        Thread.new do
          messages = run(
            prompts: prompts,
            context: context,
            config: config,
            cancellation: cancellation,
            emitter: ->(event) { stream.push(event) }
          )
          stream.close(messages)
        rescue StandardError => error
          error_message = Messages.assistant(
            content: [Messages.text("")],
            api: config.fetch(:model).fetch(:api),
            provider: config.fetch(:model).fetch(:provider),
            model: config.fetch(:model).fetch(:id),
            stop_reason: :error,
            error_message: error.message
          )
          stream.push(type: :agent_end, messages: [error_message])
          stream.close([error_message])
        end
        stream
      end
    end

    def initialize(context:, config:, cancellation: nil, emitter: nil)
      @context = {
        system_prompt: context[:system_prompt].to_s,
        messages: Array(context[:messages]).map { |message| Messages.deep_copy(message) },
        tools: Array(context[:tools])
      }
      @config = config
      @emitter = emitter || ->(_event) {}
      @emit_mutex = Mutex.new
      @provider_registry = config[:provider_registry] || RubyPi.providers
      @cancellation = resolve_cancellation(cancellation)
    end

    def run(prompts)
      prompts = Array(prompts).map { |prompt| Messages.deep_copy(prompt) }
      new_messages = prompts.map { |prompt| Messages.deep_copy(prompt) }
      current_context = {
        system_prompt: @context[:system_prompt],
        messages: @context[:messages] + prompts.map { |prompt| Messages.deep_copy(prompt) },
        tools: @context[:tools]
      }

      emit(type: :agent_start)
      emit(type: :turn_start)
      prompts.each do |prompt|
        emit(type: :message_start, message: Messages.deep_copy(prompt))
        emit(type: :message_end, message: Messages.deep_copy(prompt))
      end

      run_loop(current_context, new_messages)
      new_messages
    end

    def continue
      raise ArgumentError, "Cannot continue: no messages in context" if @context[:messages].empty?

      last_message = @context[:messages].last
      if last_message[:role].to_sym == :assistant
        raise ArgumentError, "Cannot continue from message role: assistant"
      end

      new_messages = []
      current_context = {
        system_prompt: @context[:system_prompt],
        messages: @context[:messages].map { |message| Messages.deep_copy(message) },
        tools: @context[:tools]
      }

      emit(type: :agent_start)
      emit(type: :turn_start)
      run_loop(current_context, new_messages)
      new_messages
    end

    private

    def run_loop(current_context, new_messages)
      first_turn = true
      pending_messages = safe_messages(@config[:get_steering_messages])

      loop do
        has_more_tool_calls = true

        while has_more_tool_calls || pending_messages.any?
          if first_turn
            first_turn = false
          else
            emit(type: :turn_start)
          end

          pending_messages.each do |message|
            emit(type: :message_start, message: Messages.deep_copy(message))
            emit(type: :message_end, message: Messages.deep_copy(message))
            current_context[:messages] << Messages.deep_copy(message)
            new_messages << Messages.deep_copy(message)
          end
          pending_messages = []

          assistant_message = stream_assistant_response(current_context)
          new_messages << Messages.deep_copy(assistant_message)

          if [:error, :aborted].include?(assistant_message[:stop_reason].to_sym)
            emit(type: :turn_end, message: Messages.deep_copy(assistant_message), tool_results: [])
            emit(type: :agent_end, messages: new_messages.map { |message| Messages.deep_copy(message) })
            return
          end

          tool_calls = Messages.tool_calls(assistant_message)
          has_more_tool_calls = tool_calls.any?

          tool_results = []
          if has_more_tool_calls
            tool_results.concat(execute_tool_calls(current_context, assistant_message, tool_calls))
            tool_results.each do |tool_result|
              current_context[:messages] << Messages.deep_copy(tool_result)
              new_messages << Messages.deep_copy(tool_result)
            end
          end

          emit(
            type: :turn_end,
            message: Messages.deep_copy(assistant_message),
            tool_results: tool_results.map { |tool_result| Messages.deep_copy(tool_result) }
          )

          pending_messages = safe_messages(@config[:get_steering_messages])
        end

        follow_up_messages = safe_messages(@config[:get_follow_up_messages])
        if follow_up_messages.any?
          pending_messages = follow_up_messages
          next
        end

        break
      end

      emit(type: :agent_end, messages: new_messages.map { |message| Messages.deep_copy(message) })
    end

    def stream_assistant_response(current_context)
      @cancellation.raise_if_cancelled!

      messages = current_context[:messages]
      if @config[:transform_context]
        messages = @config[:transform_context].call(
          messages.map { |message| Messages.deep_copy(message) },
          @cancellation
        )
      end

      llm_messages = @config[:convert_to_llm].call(messages.map { |message| Messages.deep_copy(message) })
      llm_context = {
        system_prompt: current_context[:system_prompt],
        messages: llm_messages,
        tools: Array(current_context[:tools]).map { |tool| tool.respond_to?(:to_llm) ? tool.to_llm : tool }
      }

      response = stream_provider(llm_context)
      partial_message = nil
      added_partial = false

      response.each do |event|
        type = event[:type].to_sym

        case type
        when :start
          partial_message = Messages.deep_copy(event[:partial])
          current_context[:messages] << partial_message
          added_partial = true
          emit(type: :message_start, message: Messages.deep_copy(partial_message))
        when *UPDATE_EVENT_TYPES
          next unless partial_message

          partial_message = Messages.deep_copy(event[:partial])
          current_context[:messages][-1] = partial_message
          emit(
            type: :message_update,
            assistant_message_event: Messages.deep_copy(event),
            message: Messages.deep_copy(partial_message)
          )
        when :done, :error
          final_message = Messages.deep_copy(response.result)
          if added_partial
            current_context[:messages][-1] = final_message
          else
            current_context[:messages] << final_message
            emit(type: :message_start, message: Messages.deep_copy(final_message))
          end
          emit(type: :message_end, message: Messages.deep_copy(final_message))
          return final_message
        end
      end

      final_message = Messages.deep_copy(response.result)
      if added_partial
        current_context[:messages][-1] = final_message
      else
        current_context[:messages] << final_message
        emit(type: :message_start, message: Messages.deep_copy(final_message))
      end
      emit(type: :message_end, message: Messages.deep_copy(final_message))
      final_message
    end

    def stream_provider(llm_context)
      model = @config.fetch(:model)
      auth = RubyPi::Auth.resolve(
        model[:provider],
        api_key: @config[:api_key],
        get_api_key: @config[:get_api_key]
      )

      options = {
        api_key: auth[:api_key],
        auth_headers: auth[:headers],
        reasoning: @config[:reasoning],
        session_id: @config[:session_id],
        metadata: @config[:metadata],
        stream_options: @config[:stream_options]
      }.compact

      if @config[:stream]
        return @config[:stream].call(model: model, context: llm_context, options: options, cancellation: @cancellation)
      end

      @provider_registry.fetch(model[:api]).stream(
        model: model,
        context: llm_context,
        options: options,
        cancellation: @cancellation
      )
    end

    def execute_tool_calls(current_context, assistant_message, tool_calls)
      mode = (@config[:tool_execution] || :parallel).to_sym
      if mode == :sequential
        execute_tool_calls_sequential(current_context, assistant_message, tool_calls)
      else
        execute_tool_calls_parallel(current_context, assistant_message, tool_calls)
      end
    end

    def execute_tool_calls_sequential(current_context, assistant_message, tool_calls)
      tool_calls.map do |tool_call|
        emit_tool_execution_start(tool_call)
        preparation = prepare_tool_call(current_context, assistant_message, tool_call)
        if preparation[:kind] == :immediate
          emit_tool_call_outcome(tool_call, preparation[:result], preparation[:is_error])
        else
          executed = execute_prepared_tool_call(preparation)
          finalize_executed_tool_call(current_context, assistant_message, preparation, executed)
        end
      end
    end

    def execute_tool_calls_parallel(current_context, assistant_message, tool_calls)
      outcomes = Array.new(tool_calls.length)
      runnable_calls = []

      tool_calls.each_with_index do |tool_call, index|
        emit_tool_execution_start(tool_call)
        preparation = prepare_tool_call(current_context, assistant_message, tool_call)
        if preparation[:kind] == :immediate
          outcomes[index] = {
            tool_call: tool_call,
            result: preparation[:result],
            is_error: preparation[:is_error]
          }
        else
          runnable_calls << { index: index, prepared: preparation }
        end
      end

      running_calls = runnable_calls.map do |call|
        queue = Queue.new
        thread = Thread.new do
          queue << execute_prepared_tool_call(call[:prepared])
        end
        call.merge(queue: queue, thread: thread)
      end

      running_calls.each do |running|
        executed = running[:queue].pop
        running[:thread].join
        outcomes[running[:index]] = {
          prepared: running[:prepared],
          executed: executed
        }
      end

      outcomes.map do |outcome|
        if outcome[:prepared]
          finalize_executed_tool_call(current_context, assistant_message, outcome[:prepared], outcome[:executed])
        else
          emit_tool_call_outcome(outcome[:tool_call], outcome[:result], outcome[:is_error])
        end
      end
    end

    def emit_tool_execution_start(tool_call)
      emit(
        type: :tool_execution_start,
        tool_call_id: tool_call[:id],
        tool_name: tool_call[:name],
        args: Messages.deep_copy(tool_call[:arguments])
      )
    end

    def prepare_tool_call(current_context, assistant_message, tool_call)
      tool = Array(current_context[:tools]).find { |candidate| candidate.name == tool_call[:name].to_s }
      unless tool
        return {
          kind: :immediate,
          result: create_error_tool_result("Tool #{tool_call[:name]} not found"),
          is_error: true
        }
      end

      prepared_tool_call = prepare_tool_call_arguments(tool, tool_call)
      validated_args = tool.validate_arguments!(prepared_tool_call[:arguments])

      if @config[:before_tool_call]
        before_result = @config[:before_tool_call].call(
          {
            assistant_message: Messages.deep_copy(assistant_message),
            tool_call: Messages.deep_copy(tool_call),
            args: Messages.deep_copy(validated_args),
            context: snapshot_context(current_context)
          },
          @cancellation
        )
        if before_result && before_result[:block]
          return {
            kind: :immediate,
            result: create_error_tool_result(before_result[:reason] || "Tool execution was blocked"),
            is_error: true
          }
        end
      end

      {
        kind: :prepared,
        tool_call: tool_call,
        tool: tool,
        args: validated_args
      }
    rescue StandardError => error
      {
        kind: :immediate,
        result: create_error_tool_result(error.message),
        is_error: true
      }
    end

    def prepare_tool_call_arguments(tool, tool_call)
      prepared_arguments = tool.prepare_arguments(tool_call[:arguments])
      return tool_call if prepared_arguments == tool_call[:arguments]

      tool_call.merge(arguments: prepared_arguments)
    end

    def execute_prepared_tool_call(prepared)
      result = prepared[:tool].call(
        tool_call_id: prepared[:tool_call][:id],
        arguments: Messages.deep_copy(prepared[:args]),
        cancellation: @cancellation
      ) do |partial_result|
        emit(
          type: :tool_execution_update,
          tool_call_id: prepared[:tool_call][:id],
          tool_name: prepared[:tool_call][:name],
          args: Messages.deep_copy(prepared[:tool_call][:arguments]),
          partial_result: normalize_tool_result(partial_result)
        )
      end
      { result: normalize_tool_result(result), is_error: false }
    rescue StandardError => error
      { result: create_error_tool_result(error.message), is_error: true }
    end

    def finalize_executed_tool_call(current_context, assistant_message, prepared, executed)
      result = executed[:result]
      is_error = executed[:is_error]

      if @config[:after_tool_call]
        after_result = @config[:after_tool_call].call(
          {
            assistant_message: Messages.deep_copy(assistant_message),
            tool_call: Messages.deep_copy(prepared[:tool_call]),
            args: Messages.deep_copy(prepared[:args]),
            result: Messages.deep_copy(result),
            is_error: is_error,
            context: snapshot_context(current_context)
          },
          @cancellation
        )
        if after_result
          result = {
            content: after_result.key?(:content) ? Messages.deep_copy(after_result[:content]) : result[:content],
            details: after_result.key?(:details) ? Messages.deep_copy(after_result[:details]) : result[:details]
          }
          is_error = after_result.key?(:is_error) ? !!after_result[:is_error] : is_error
        end
      end

      emit_tool_call_outcome(prepared[:tool_call], result, is_error)
    end

    def create_error_tool_result(message)
      {
        content: [Messages.text(message)],
        details: {}
      }
    end

    def emit_tool_call_outcome(tool_call, result, is_error)
      emit(
        type: :tool_execution_end,
        tool_call_id: tool_call[:id],
        tool_name: tool_call[:name],
        result: Messages.deep_copy(result),
        is_error: !!is_error
      )

      tool_result_message = Messages.tool_result(
        tool_call_id: tool_call[:id],
        tool_name: tool_call[:name],
        content: result[:content],
        details: result[:details],
        is_error: is_error
      )

      emit(type: :message_start, message: Messages.deep_copy(tool_result_message))
      emit(type: :message_end, message: Messages.deep_copy(tool_result_message))
      tool_result_message
    end

    def normalize_tool_result(result)
      unless result.is_a?(Hash)
        return {
          content: Array(result).map { |item| item.is_a?(String) ? Messages.text(item) : Messages.deep_copy(item) },
          details: {}
        }
      end

      content = result.key?(:content) ? result[:content] : result["content"]
      details = result.key?(:details) ? result[:details] : result["details"]

      {
        content: Messages.normalize_user_content(content.nil? ? [] : content),
        details: details.nil? ? {} : Messages.deep_copy(details)
      }
    end

    def snapshot_context(current_context)
      {
        system_prompt: current_context[:system_prompt],
        messages: current_context[:messages].map { |message| Messages.deep_copy(message) },
        tools: Array(current_context[:tools])
      }
    end

    def emit(event)
      @emit_mutex.synchronize do
        @emitter.call(Messages.deep_copy(event))
      end
    end

    def safe_messages(callback)
      return [] unless callback

      Array(callback.call).map { |message| Messages.deep_copy(message) }
    rescue StandardError
      []
    end

    def resolve_cancellation(cancellation)
      return cancellation if cancellation.is_a?(Cancellation::Token)
      return cancellation.token if cancellation.respond_to?(:token)

      Cancellation::Source.new.token
    end
  end
end
