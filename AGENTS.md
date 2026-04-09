## Build & Run

- Use Bundler for all commands.
- Install dependencies with `bundle install`.
- Build the gem with `bundle exec rake build`.
- Run the full local CI flow with `./bin/ci`.
- Lint with `bundle exec rubocop`.
- This repo is a library, not an app. There is no long-running server or CLI entrypoint to boot.

## Validation

Run these after implementing to get immediate feedback:

- Tests: `bundle exec rake test`
- Lint: `bundle exec rubocop`

## Operational Notes

- Smoke-check the library loads with `bundle exec ruby -e 'require "ruby_pi"; puts RubyPi::VERSION'`.
- `./bin/ci` runs `bundle install`, a require smoke test, `./bin/secrets`, RuboCop, tests, and gem build.
- `./bin/secrets` requires `gitleaks` on PATH.
- Built artifacts are written to `pkg/`.
- Optional pre-commit hook setup: `git config core.hooksPath .githooks`.
- Live OpenAI recording tests depend on `OPENAI_API_KEY`; most day-to-day work should rely on the regular test suite.

### Codebase Patterns

- Keep the public entrypoint in `lib/ruby_pi.rb`; implementation lives under `lib/ruby_pi/`.
- Preserve the normalized message shape in `RubyPi::Messages` (`:user`, `:assistant`, `:tool_result`) and use its helpers instead of hand-rolling message hashes.
- Follow the existing `deep_copy` pattern when moving messages/events across agent state, provider streams, and callbacks.
- `RubyPi::Agent` is the stateful threaded wrapper; `RubyPi::AgentLoop` owns the prompt -> stream -> tool execution loop.
- Providers should emit normalized stream events through `RubyPi::Stream`; tool and text deltas are reconstructed incrementally.
- Prefer small focused classes/modules over abstractions. The repo favors direct data hashes and explicit control flow.
- Treat tests as the behavioral spec. Add or update focused `test/*_test.rb` coverage alongside changes.
