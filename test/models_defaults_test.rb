# frozen_string_literal: true

require_relative "test_helper"

class ModelsDefaultsTest < Minitest::Test
  def test_openai_latest_models_are_registered
    gpt_54 = RubyPi.models.fetch("openai", "openai/gpt-5.4")
    gpt_54_mini = RubyPi.models.fetch("openai", "openai/gpt-5.4-mini")

    assert_equal "https://api.openai.com/v1", gpt_54[:base_url]
    assert_equal true, gpt_54[:reasoning]
    assert_equal true, gpt_54[:compat][:supports_reasoning_effort]
    assert_equal "max_completion_tokens", gpt_54[:compat][:max_tokens_field]

    assert_equal "https://api.openai.com/v1", gpt_54_mini[:base_url]
    assert_equal true, gpt_54_mini[:reasoning]
    assert_equal true, gpt_54_mini[:compat][:supports_reasoning_effort]
    assert_equal "max_completion_tokens", gpt_54_mini[:compat][:max_tokens_field]
  end
end
