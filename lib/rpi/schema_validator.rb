# frozen_string_literal: true

module Rpi
  module SchemaValidator
    class ValidationError < StandardError; end

    module_function

    def validate!(schema, value, tool_name: nil)
      return value if schema.nil? || schema.empty?

      coerced, errors = validate_schema(schema, Messages.deep_copy(value), "$")
      return coerced if errors.empty?

      prefix = tool_name ? "Validation failed for tool \"#{tool_name}\":" : "Validation failed:"
      formatted_errors = errors.map { |error| "  - #{error}" }.join("\n")
      raise ValidationError, "#{prefix}\n#{formatted_errors}"
    end

    def validate_schema(schema, value, path)
      schema = symbolize_keys(schema)
      errors = []

      if schema.key?(:const) && value != schema[:const]
        errors << "#{path} must equal #{schema[:const].inspect}"
        return [value, errors]
      end

      if schema.key?(:enum) && !schema[:enum].include?(value)
        value = coerce_enum(schema[:enum], value)
        errors << "#{path} must be one of #{schema[:enum].map(&:inspect).join(', ')}" unless schema[:enum].include?(value)
      end

      type = schema[:type]
      return [value, errors] unless type

      case type.to_s
      when "object"
        validate_object(schema, value, path, errors)
      when "array"
        validate_array(schema, value, path, errors)
      else
        validate_scalar(schema, value, path, errors)
      end
    end

    def validate_object(schema, value, path, errors)
      unless value.is_a?(Hash)
        errors << "#{path} must be an object"
        return [value, errors]
      end

      properties = symbolize_keys(schema[:properties] || {})
      required = Array(schema[:required]).map(&:to_sym)
      coerced = {}

      value.each do |key, raw_value|
        symbol_key = key.to_sym
        property_schema = properties[symbol_key]

        if property_schema
          next_value, child_errors = validate_schema(property_schema, raw_value, "#{path}.#{symbol_key}")
          coerced[key] = next_value
          errors.concat(child_errors)
        elsif schema[:additional_properties] == false || schema[:additionalProperties] == false
          errors << "#{path}.#{symbol_key} is not allowed"
        else
          coerced[key] = raw_value
        end
      end

      required.each do |required_key|
        has_key = value.key?(required_key) || value.key?(required_key.to_s)
        errors << "#{path}.#{required_key} is required" unless has_key
      end

      [coerced, errors]
    end

    def validate_array(schema, value, path, errors)
      unless value.is_a?(Array)
        errors << "#{path} must be an array"
        return [value, errors]
      end

      item_schema = schema[:items]
      return [value, errors] unless item_schema

      coerced = value.each_with_index.map do |item, index|
        next_value, child_errors = validate_schema(item_schema, item, "#{path}[#{index}]")
        errors.concat(child_errors)
        next_value
      end

      [coerced, errors]
    end

    def validate_scalar(schema, value, path, errors)
      coerced = coerce_type(schema[:type], value)

      case schema[:type].to_s
      when "string"
        errors << "#{path} must be a string" unless coerced.is_a?(String)
      when "integer"
        errors << "#{path} must be an integer" unless coerced.is_a?(Integer)
      when "number"
        errors << "#{path} must be a number" unless coerced.is_a?(Numeric)
      when "boolean"
        errors << "#{path} must be a boolean" unless coerced == true || coerced == false
      end

      if schema.key?(:enum) && !schema[:enum].include?(coerced)
        errors << "#{path} must be one of #{schema[:enum].map(&:inspect).join(', ')}"
      end

      [coerced, errors]
    end

    def coerce_type(type, value)
      case type.to_s
      when "string"
        value.is_a?(String) ? value : value.to_s
      when "integer"
        return value if value.is_a?(Integer)
        return value.to_i if value.is_a?(String) && value.match?(/\A-?\d+\z/)
        return value.to_i if value.is_a?(Float) && value.finite? && value == value.to_i

        value
      when "number"
        return value if value.is_a?(Numeric)
        return Float(value) if value.is_a?(String) && value.match?(/\A-?\d+(\.\d+)?\z/)

        value
      when "boolean"
        return value if value == true || value == false
        return true if value == "true"
        return false if value == "false"

        value
      else
        value
      end
    rescue ArgumentError
      value
    end

    def coerce_enum(enum_values, value)
      enum_values.each do |candidate|
        return candidate if candidate.to_s == value.to_s
      end
      value
    end

    def symbolize_keys(object)
      case object
      when Hash
        object.each_with_object({}) do |(key, value), copy|
          copy[key.respond_to?(:to_sym) ? key.to_sym : key] = symbolize_keys(value)
        end
      when Array
        object.map { |item| symbolize_keys(item) }
      else
        object
      end
    end
  end
end
