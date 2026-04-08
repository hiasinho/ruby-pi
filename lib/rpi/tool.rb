# frozen_string_literal: true

module Rpi
  class Tool
    attr_reader :name, :label, :description, :schema

    def self.define(name:, description:, label: nil, schema: { type: "object" }, prepare_arguments: nil, &block)
      new(name: name, description: description, label: label, schema: schema, prepare_arguments: prepare_arguments, executor: block)
    end

    def initialize(name:, description:, label: nil, schema: { type: "object" }, prepare_arguments: nil, executor: nil)
      raise ArgumentError, "executor is required" unless executor

      @name = name.to_s
      @label = (label || name).to_s
      @description = description.to_s
      @schema = schema
      @prepare_arguments = prepare_arguments
      @executor = executor
    end

    def prepare_arguments(raw_arguments)
      return raw_arguments unless @prepare_arguments

      @prepare_arguments.call(Messages.deep_copy(raw_arguments))
    end

    def validate_arguments!(arguments)
      SchemaValidator.validate!(@schema, arguments, tool_name: @name)
    end

    def call(tool_call_id:, arguments:, cancellation:, &on_update)
      if keyword_executor?
        @executor.call(
          tool_call_id: tool_call_id,
          arguments: arguments,
          cancellation: cancellation,
          on_update: on_update
        )
      else
        case @executor.arity
        when 0
          @executor.call
        when 1
          @executor.call(arguments)
        when 2
          @executor.call(arguments, cancellation)
        when 3
          @executor.call(tool_call_id, arguments, cancellation)
        else
          @executor.call(tool_call_id, arguments, cancellation, on_update)
        end
      end
    end

    def to_llm
      {
        name: @name,
        description: @description,
        parameters: @schema
      }
    end

    private

    def keyword_executor?
      @executor.parameters.any? { |kind, _| [:key, :keyreq, :keyrest].include?(kind) }
    end
  end
end
