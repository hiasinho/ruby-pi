# frozen_string_literal: true

require "bundler/setup"
require "minitest/autorun"
require "ruby_pi"

class GemRequireTest < Minitest::Test
  def test_requires_ruby_pi_from_the_gem_load_path
    assert_match(/\A\d+\.\d+\.\d+\z/, RubyPi::VERSION)
  end
end
