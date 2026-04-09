# frozen_string_literal: true

require_relative "test_helper"

class VersionTest < Minitest::Test
  def test_has_version
    refute_nil RubyPi::VERSION
  end
end
