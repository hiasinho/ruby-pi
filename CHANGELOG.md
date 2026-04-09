# Changelog

## 0.1.0

- Initial gem packaging for RubyPi
- Added `ruby_pi.gemspec`
- Added `RubyPi::VERSION`
- Switched Bundler setup to use `gemspec`
- Updated README examples to use `require "ruby_pi"`
- Added local `bin/ci` and `bin/secrets` scripts
- Added `Rakefile` tasks for test, build, and release
- Added a checked-in pre-commit hook for secret scanning
- Added GitHub Actions workflows for CI and release
- Dropped Ruby 3.3 support
- Added packaging smoke test
