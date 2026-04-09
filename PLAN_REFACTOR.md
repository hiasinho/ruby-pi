# Refactor plan

## Agent run protocol

You must follow these rules exactly:

1. Read this entire file first.
2. Find the first unchecked item in the `## Tasks` section.
3. Work on that one task only.
4. Do not fix, refactor, or clean up any lower-priority task in the same run, even if it is nearby.
5. Make the smallest complete change that resolves the selected task.
6. Run the most relevant tests for that task, then run the full test suite if the targeted tests pass.
7. Update this file before finishing:
   - mark the task as done by changing `- [ ]` to `- [x]`
   - add a short note under the task with what changed
8. Commit exactly that one task with one git commit.
9. Stop after the commit.

Do not continue to the next task in the same run.
Do not batch tasks.
Do not do opportunistic cleanups.

If the selected task turns out to be blocked, document the blocker under that task, commit only the blocker note if needed, and stop. Do not start the next task.

## Current state

Current test status from review:

- `bundle exec ruby -Itest -e 'Dir["test/*_test.rb"].sort.each { |f| require_relative f }'`
- 25 tests
- 2 failures
- both failures are in `test/http_client_test.rb`

## Tasks

- [x] P1 - Fix streaming and cancellation semantics in `lib/ruby_pi/http/client.rb`
  - Problem:
    - `Net::HTTP#read_body` yields arbitrary buffered fragments, not stable transport chunk boundaries.
    - cancellation is only checked before yielding to the callback
    - if the callback cancels and no further read occurs, the request can still finish successfully
  - Evidence:
    - failing tests:
      - `HttpClientTest#test_post_stream_yields_chunks`
      - `HttpClientTest#test_post_stream_raises_when_cancelled_mid_stream`
  - Mitigation:
    - treat callback payloads as arbitrary bytes, not as semantic chunks
    - re-check cancellation immediately after yielding to the callback
    - keep SSE framing responsibility in `lib/ruby_pi/http/sse_parser.rb`
  - Acceptance:
    - both failing `HttpClientTest` tests pass
    - full test suite passes
  - Note:
    - re-checked cancellation after each streamed callback and updated streaming tests to parse SSE events without assuming transport chunk boundaries

- [x] P2 - Fix tool result normalization in `lib/ruby_pi/agent_loop.rb`
  - Problem:
    - `normalize_tool_result` only accepts hashes when `result[:content]` is already an array
    - common shapes like `{ content: "ok", details: {} }` or `{ "content" => "ok" }` are mangled
  - Mitigation:
    - normalize hash-shaped results field by field
    - accept symbol and string keys
    - normalize `content` through one path
    - default `details` to `{}`
  - Acceptance:
    - add or update tests for string and hash-shaped tool results
    - full test suite passes
  - Note:
    - normalized symbol-keyed and string-keyed hash results through `Messages.normalize_user_content` and added agent tests for preserved details and default `{}` details

- [x] P3 - Stop swallowing queue callback errors in `lib/ruby_pi/agent_loop.rb`
  - Problem:
    - `safe_messages` rescues `StandardError` and silently returns `[]`
    - bugs in steering or follow-up callbacks are hidden and messages can be dropped
  - Mitigation:
    - do not silently rescue callback failures
    - let failures surface, or convert them into a visible agent error path
  - Acceptance:
    - add or update tests covering callback failure behavior
    - full test suite passes
  - Note:
    - let steering and follow-up callback exceptions surface from `safe_messages` and added agent loop tests for both failure paths

- [x] P4 - Split local transport options from provider payload options in `lib/ruby_pi/providers/openai_completions.rb`
  - Problem:
    - `options[:stream_options]` is used both for HTTP timeout handling and for upstream API payload fields
    - local options like `{ timeout: 5 }` can leak into the provider request body
  - Mitigation:
    - separate transport config from upstream payload config
    - whitelist payload keys that are actually meant for the API
  - Acceptance:
    - add or update tests proving timeout stays local and does not leak into API payload unless explicitly intended
    - full test suite passes
  - Note:
    - kept `timeout` local to the HTTP client, whitelisted payload `stream_options` to `include_usage`, and added an adapter test covering both behaviors

- [x] P5 - Simplify parallel tool execution in `lib/ruby_pi/agent_loop.rb`
  - Problem:
    - parallel tool execution uses one thread plus one queue per tool call
    - this is more moving parts than needed
  - Mitigation:
    - keep the behavior but reduce machinery
    - prefer a simpler collection strategy such as thread values, or reduce concurrency complexity
    - preserve tool result order
  - Acceptance:
    - existing ordering behavior remains intact
    - tests still prove tool result order is preserved
    - full test suite passes
  - Note:
    - replaced per-call queue collection with thread values in parallel tool execution while keeping ordered results and the existing ordering test coverage

- [x] P6 - Make agent failure events consistent in `lib/ruby_pi/agent.rb`
  - Problem:
    - `handle_run_failure` mutates state directly and emits only `:agent_end`
    - subscribers do not see the normal message lifecycle for failure messages
  - Mitigation:
    - route failures through the same event path as normal assistant messages
    - or emit equivalent `:message_end` and `:turn_end` events before `:agent_end`
  - Acceptance:
    - add or update tests for subscriber-visible failure events
    - full test suite passes
  - Note:
    - routed run failures through `:message_start`, `:message_end`, `:turn_end`, and `:agent_end` and added an agent test covering the subscriber-visible failure lifecycle

- [x] P7 - Remove duplicated enum validation logic in `lib/ruby_pi/schema_validator.rb`
  - Problem:
    - enum validation happens once in `validate_schema` and again in `validate_scalar`
    - this increases complexity and can duplicate errors
  - Mitigation:
    - coerce first, then validate enum once
  - Acceptance:
    - add or update tests for enum validation and coercion
    - full test suite passes
  - Note:
    - validate enum values once after type coercion in `validate_schema` and added tests for integer enum coercion and single-error enum failures

- [x] P8 - Remove or integrate dead code in `lib/ruby_pi/message_transformer.rb`
  - Problem:
    - file is required from `lib/ruby_pi.rb` but appears unused by `lib/` and `test/`
    - it overlaps with conversion logic in `lib/ruby_pi/providers/openai_completions.rb`
  - Mitigation:
    - either remove it entirely or wire it into the real message conversion path
    - prefer deletion if it is truly unused
  - Acceptance:
    - no dead require remains
    - behavior stays covered by tests
    - full test suite passes
  - Note:
    - removed the unused `message_transformer` require from `lib/ruby_pi.rb` and deleted the dead file after confirming nothing under `lib/` or `test/` referenced it

## Notes for the agent

- Keep changes minimal.
- Prefer the simplest working fix.
- Do not introduce new abstractions unless the selected task truly requires one.
- Do not change task ordering.
- Do not mark future tasks done.
- After committing the selected task, stop immediately.
