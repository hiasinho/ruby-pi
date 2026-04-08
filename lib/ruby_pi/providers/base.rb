# frozen_string_literal: true

module RubyPi
  module Providers
    class Base
      def stream(model:, context:, options:, cancellation:)
        raise NotImplementedError, "#{self.class} must implement #stream"
      end
    end
  end
end
