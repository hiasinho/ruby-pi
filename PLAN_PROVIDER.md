# Provider integration plan

## Goal

Add real multi-provider LLM support to `rpi` using the same core architecture as `pi-mono`:

- dispatch by protocol adapter, not vendor name
- keep `provider` and `api` separate
- support many vendors through one adapter plus compat flags
- start with OpenAI-compatible support first

## What pi does

pi splits provider support into two layers:

- `provider`
  - vendor/account identity
  - examples: `openai`, `openrouter`, `github-copilot`, `groq`
- `api`
  - protocol adapter identity
  - examples: `openai-completions`, `openai-responses`, `anthropic-messages`

Runtime dispatch is by `model.api`.
That means one adapter can support many vendors.

Examples from pi:

- `openrouter` -> `openai-completions`
- `groq` -> `openai-completions`
- `cerebras` -> `openai-completions`
- `xai` -> `openai-completions`
- `openai` -> `openai-responses`
- `anthropic` -> `anthropic-messages`

## Current state in this repo

Already present:

- `lib/ruby_pi/agent_loop.rb`
- `lib/ruby_pi/agent.rb`
- `lib/ruby_pi/messages.rb`
- `lib/ruby_pi/tool.rb`
- `lib/ruby_pi/provider_registry.rb`
- `lib/ruby_pi/model_registry.rb`
- `lib/ruby_pi/stream.rb`
- `lib/ruby_pi/cancellation.rb`

Missing for real provider support:

- real provider adapters
- HTTP/SSE transport
- request/response mapping
- auth resolution
- compat flags
- provider-level tests

## Principles

1. Dispatch by `model[:api]`, not `model[:provider]`
2. Put vendor quirks in model metadata and compat config
3. Build one OpenAI-compatible adapter first
4. Keep adapters stateless where possible
5. Normalize messages once, then map them into provider payloads
6. Make cancellation work through the HTTP streaming layer
7. Add replay/cross-provider normalization before growing the provider matrix

## Phase 1: formalize the adapter contract

Create:

- `lib/ruby_pi/providers/base.rb`

Define the contract every adapter must implement:

```ruby
module RubyPi
  module Providers
    class Base
      def stream(model:, context:, options:, cancellation:)
        raise NotImplementedError
      end
    end
  end
end
```

Document expected stream behavior:

- returned object must respond to:
  - `#each`
  - `#result`
- emitted event types:
  - `:start`
  - `:text_start`
  - `:text_delta`
  - `:text_end`
  - `:thinking_start`
  - `:thinking_delta`
  - `:thinking_end`
  - `:tool_call_start`
  - `:tool_call_delta`
  - `:tool_call_end`
  - `:done`
  - `:error`

Also document final assistant message expectations:

- `role: :assistant`
- `api`
- `provider`
- `model`
- `usage`
- `stop_reason`
- `error_message` when needed

## Phase 2: add a small HTTP and SSE layer

Create:

- `lib/ruby_pi/http/client.rb`
- `lib/ruby_pi/http/sse_parser.rb`

Responsibilities:

### `RubyPi::Http::Client`

- perform POST requests
- support streaming responses
- support custom headers
- support request timeouts
- support cancellation checks
- expose raw chunks to the adapter

If possible, start with standard library only:

- `net/http`

If that becomes too painful, use one gem later.

### `RubyPi::Http::SseParser`

- read `data:` lines
- accumulate event payloads
- emit parsed JSON payloads per SSE event
- ignore keepalive/comment lines
- detect `[DONE]`

## Phase 3: implement OpenAI-compatible adapter first

Create:

- `lib/ruby_pi/providers/openai_completions.rb`

Register under:

- `:openai_completions`

This adapter should support multiple vendors that speak OpenAI-compatible chat/completions APIs.

Initial target vendors:

- OpenAI-compatible local endpoints
- OpenRouter
- Groq
- Cerebras
- xAI
- maybe OpenAI chat-completions if needed

## Phase 4: add request mapping for OpenAI-compatible APIs

Inside `openai_completions.rb`, implement helpers:

- `build_headers(model, options)`
- `build_payload(model, context, options)`
- `convert_messages(context)`
- `convert_tools(context[:tools])`
- `convert_tool_result(message)`
- `map_finish_reason(reason)`
- `calculate_usage(raw_usage, model)`

### Message mapping

Map internal messages to OpenAI chat messages:

- system prompt -> `role: "system"` or compat-selected role
- user -> `role: "user"`
- assistant -> `role: "assistant"`
- tool_result -> `role: "tool"`

Handle content carefully:

- text parts -> standard text content
- images -> image_url or provider-compatible image block
- tool calls -> OpenAI tool call objects
- tool results -> tool result message with matching `tool_call_id`

### Tool mapping

Map tools to OpenAI tool definitions:

```json
{
  "type": "function",
  "function": {
    "name": "tool_name",
    "description": "...",
    "parameters": { ... }
  }
}
```

## Phase 5: implement streaming response normalization

The adapter must:

1. start with an empty partial assistant message
2. parse each stream chunk
3. accumulate:
   - text deltas
   - reasoning/thinking deltas if available
   - tool call partial JSON arguments
4. emit normalized events expected by `AgentLoop`
5. produce a final assistant message in the exact internal format

Important:

- tool call arguments often arrive incrementally
- accumulate them by tool call index/id
- parse JSON only once complete enough
- final `content` should contain normalized `:tool_call` parts

## Phase 6: introduce compat flags

Extend model metadata with a `:compat` hash.

Example shape:

```ruby
compat: {
  supports_store: false,
  supports_developer_role: false,
  max_tokens_field: "max_tokens",
  thinking_format: nil,
  requires_tool_result_name: false,
  supports_parallel_tool_calls: true,
  supports_reasoning_effort: false
}
```

Use compat flags instead of branching directly on vendor names whenever possible.

Examples where this helps:

- `max_tokens` vs `max_completion_tokens`
- `system` vs `developer` role
- extra headers
- reasoning field formats
- tool result quirks

## Phase 7: add auth resolution

Create:

- `lib/ruby_pi/auth.rb`

Responsibilities:

- resolve API keys by provider name
- support runtime override
- support env vars
- support Rails credentials later
- return provider headers if needed

Suggested resolution order:

1. explicit runtime `api_key`
2. explicit callback `get_api_key`
3. environment variable by provider
4. Rails credentials later

Initial env mapping:

- `openai` -> `OPENAI_API_KEY`
- `openrouter` -> `OPENROUTER_API_KEY`
- `groq` -> `GROQ_API_KEY`
- `cerebras` -> `CEREBRAS_API_KEY`
- `xai` -> `XAI_API_KEY`

## Phase 8: bootstrap models and providers

Create:

- `lib/ruby_pi/providers.rb`
- `lib/ruby_pi/models/defaults.rb`

### `lib/ruby_pi/providers.rb`

Register built-ins:

- `:openai_completions`

### `lib/ruby_pi/models/defaults.rb`

Add a small initial catalog:

- OpenRouter models using `api: :openai_completions`
- Groq models using `api: :openai_completions`
- OpenAI-compatible local example entries

Do not overbuild this at first.
Just add enough to exercise the path.

## Phase 9: tests

Add provider-specific tests before expanding scope.

Create:

- `test/openai_completions_adapter_test.rb`
- `test/sse_parser_test.rb`
- `test/http_client_test.rb`

Required test cases:

### SSE parser

- parses basic `data:` JSON events
- ignores keepalive lines
- detects `[DONE]`
- handles split chunks

### OpenAI-compatible adapter

- plain text completion stream
- tool call stream with incremental arguments
- final assistant message contains tool calls
- usage extraction
- stop reason mapping
- error mapping
- cancellation mid-stream

### Agent integration

- end-to-end provider test with adapter and tool loop
- queued follow-up still works through real adapter shape

## Phase 10: add OpenAI Responses after completions

After `openai_completions` works, add:

- `lib/ruby_pi/providers/openai_responses.rb`

Register under:

- `:openai_responses`

This is the likely path for native OpenAI support long term.
Do this only after the completions adapter and tests are solid.

## Phase 11: add message normalization for cross-provider replay

Create:

- `lib/ruby_pi/message_transformer.rb`

Responsibilities:

- normalize tool IDs if providers have incompatible formats
- strip provider-specific reasoning metadata when switching providers
- preserve safe text/tool history across model switches
- synthesize missing tool result placeholders if required

This matters once sessions can switch between providers mid-conversation.

## File-by-file checklist

### New files

- `lib/ruby_pi/providers/base.rb`
- `lib/ruby_pi/providers/openai_completions.rb`
- `lib/ruby_pi/providers.rb`
- `lib/ruby_pi/http/client.rb`
- `lib/ruby_pi/http/sse_parser.rb`
- `lib/ruby_pi/auth.rb`
- `lib/ruby_pi/models/defaults.rb`
- `lib/ruby_pi/message_transformer.rb`
- `test/openai_completions_adapter_test.rb`
- `test/sse_parser_test.rb`
- `test/http_client_test.rb`

### Existing files to update

- `lib/rpi.rb`
  - require provider/auth/http files
  - call built-in provider registration
- `lib/ruby_pi/model_registry.rb`
  - support compat metadata cleanly
- `lib/ruby_pi/provider_registry.rb`
  - maybe add lazy registration helpers later
- `lib/ruby_pi/agent_loop.rb`
  - optionally add message transformation hook before provider call

## Recommended order of execution

1. Add `providers/base.rb`
2. Add `http/client.rb`
3. Add `http/sse_parser.rb`
4. Add adapter tests using fixture streams
5. Implement `openai_completions.rb`
6. Add auth resolution
7. Register the adapter in `rpi.rb`
8. Add minimal default models
9. Run end-to-end agent tests against the new adapter
10. Add `openai_responses`
11. Add cross-provider replay normalization

## Non-goals for the first pass

- full OAuth support
- full generated model catalog
- Anthropic adapter
- Gemini adapter
- fancy UI/provider management
- every OpenAI-compatible edge case

## What success looks like

You should be able to do this in Rails or plain Ruby:

```ruby
require "ruby_pi"

model = RubyPi.model(
  id: "gpt-4o-mini",
  provider: "openai",
  api: :openai_completions,
  base_url: "https://api.openai.com/v1",
  compat: {
    supports_developer_role: false,
    max_tokens_field: "max_tokens"
  }
)

RubyPi.register_provider(:openai_completions, RubyPi::Providers::OpenAICompletions.new)

agent = RubyPi.build_agent(
  model: model,
  system_prompt: "You are helpful.",
  tools: []
)

agent.prompt("Hello")
puts agent.messages.last
```

Then add another model with the same adapter:

```ruby
openrouter_model = RubyPi.model(
  id: "anthropic/claude-3.7-sonnet",
  provider: "openrouter",
  api: :openai_completions,
  base_url: "https://openrouter.ai/api/v1",
  compat: {
    max_tokens_field: "max_tokens"
  }
)
```

That is the architecture to aim for.
