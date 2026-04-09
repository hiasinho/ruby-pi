# RubyPi

RubyPi is a small Ruby library for building tool-using LLM agents.

It gives you:

- a stateful `Agent` API for prompts, streaming, tools, cancellation, and follow-up turns
- an `AgentLoop` that keeps running until tool calls are resolved
- a simple `Tool` abstraction with JSON-schema-like argument validation
- provider and model registries
- a built-in OpenAI-compatible streaming adapter
- low-level HTTP, SSE parsing, and stream primitives

From the code in `lib/` and the tests in `test/`, RubyPi is designed as a lightweight agent runtime rather than a full framework.

## Installation

```bash
gem install ruby_pi
```

Supported Ruby versions for this gem:

- 3.3
- 3.4
- 4.0

The core idea is:

1. you create or select a model
2. you define tools the model may call
3. you start an agent with a prompt
4. the provider streams an assistant response
5. if the assistant emits tool calls, RubyPi validates and runs them
6. tool results are fed back into the conversation
7. the loop continues until the assistant stops

## Architecture

Main pieces in `lib/`:

- `lib/ruby_pi.rb` - entrypoint, bootstrapping, registries, model helper, `build_agent`
- `lib/ruby_pi/agent.rb` - high-level stateful agent API
- `lib/ruby_pi/agent_loop.rb` - prompt/tool/prompt orchestration loop
- `lib/ruby_pi/tool.rb` - tool definition, argument preparation, validation, execution
- `lib/ruby_pi/messages.rb` - canonical message/content-part helpers
- `lib/ruby_pi/providers/openai_completions.rb` - built-in OpenAI-compatible streaming provider
- `lib/ruby_pi/http/client.rb` - POST and streaming POST with cancellation support
- `lib/ruby_pi/http/sse_parser.rb` - SSE parser for streamed JSON events
- `lib/ruby_pi/stream.rb` - enumerable event stream with final result
- `lib/ruby_pi/schema_validator.rb` - lightweight schema validation/coercion
- `lib/ruby_pi/auth.rb` - API key and auth header resolution
- `lib/ruby_pi/provider_registry.rb`, `lib/ruby_pi/model_registry.rb` - registries
- `lib/ruby_pi/models/defaults.rb` - built-in model definitions

## Message model

RubyPi uses a small internal message format.

Roles:

- `:user`
- `:assistant`
- `:tool_result`

Content parts:

- `RubyPi::Messages.text("...")`
- `RubyPi::Messages.image(data:, mime_type:)`
- `RubyPi::Messages.thinking("...")`
- `RubyPi::Messages.tool_call(id:, name:, arguments:)`

Assistant messages can contain mixed content, including text, thinking, and tool calls.
Tool results are separate messages linked by `tool_call_id`.

## How the agent loop works

`RubyPi::AgentLoop` is the engine behind the higher-level `Agent` class.

For each run it:

1. emits `:agent_start` and `:turn_start`
2. appends new user messages to context
3. converts the current conversation into provider-specific LLM messages
4. streams the assistant response
5. accumulates text, thinking, and tool-call deltas into one assistant message
6. if tool calls are present, validates and executes them
7. emits tool result messages
8. starts another turn with those tool results in context
9. repeats until there are no more tool calls and no queued follow-up messages
10. emits `:agent_end`

Two queue types are supported while an agent is active:

- `steer(...)` adds messages that are injected before the next model turn inside the current run
- `follow_up(...)` adds messages that start a new turn after the current tool loop settles

Tests in `test/agent_test.rb` show that follow-up prompts can be queued while a run is still in progress.

## Quick start

Require the gem with:

```ruby
require "ruby_pi"
```

Pick a registered model and create an agent:

```ruby
require "ruby_pi"

model = RubyPi.models.fetch("openai", "openai/gpt-4o-mini")

agent = RubyPi.build_agent(
  model: model,
  system_prompt: "You are helpful.",
  api_key: ENV["OPENAI_API_KEY"]
)

agent.prompt("Write a haiku about Ruby.")
puts agent.messages.last[:content].first[:text]
```

`Agent#prompt` is synchronous. It starts a run and waits for it to finish.

## Using tools

Tools are first-class. Define them with `RubyPi::Tool.define`:

```ruby
require "ruby_pi"

double = RubyPi::Tool.define(
  name: "double",
  description: "Double a number",
  schema: {
    type: "object",
    properties: {
      value: { type: "integer" }
    },
    required: ["value"],
    additionalProperties: false
  }
) do |arguments, _cancellation|
  result = arguments["value"] * 2
  {
    content: [RubyPi::Messages.text(result.to_s)],
    details: { doubled: result }
  }
end

model = RubyPi.model(
  id: "local/openai-compatible",
  provider: "local",
  api: :openai_completions,
  base_url: "http://localhost:11434/v1"
)

agent = RubyPi::Agent.new(
  model: model,
  system_prompt: "Use tools when needed.",
  tools: [double]
)

agent.prompt("double 21")
puts agent.messages.last[:content].first[:text]
# => Result: 42
```

This flow is exercised in `test/agent_test.rb` and `test/openai_completions_adapter_test.rb`.

### Tool execution details

RubyPi will:

- find the tool by name
- optionally preprocess arguments via `prepare_arguments`
- validate arguments against the schema
- run `before_tool_call` if configured
- execute the tool
- normalize the result into `{ content:, details: }`
- run `after_tool_call` if configured
- append a `:tool_result` message

Tool calls can run:

- `:parallel` by default
- `:sequential` if configured

Even in parallel mode, tool result ordering is preserved to match the assistant's tool call order. This is explicitly tested in `AgentParallelOrderingTest`.

## Streaming and events

There are two streaming layers:

1. provider streams, returned by adapters like `OpenAICompletions#stream`
2. agent events, delivered through `Agent#subscribe`

Example:

```ruby
agent = RubyPi::Agent.new(model: model)

unsubscribe = agent.subscribe do |event, cancellation_token|
  case event[:type]
  when :message_update
    partial = event[:message]
    puts partial.inspect
  when :tool_execution_start
    puts "running #{event[:tool_name]}"
  when :agent_end
    puts "done"
  end
end

agent.start("Hello")
agent.wait_until_idle
unsubscribe.call
```

High-level event types emitted by the agent loop include:

- `:agent_start`
- `:turn_start`
- `:message_start`
- `:message_update`
- `:message_end`
- `:tool_execution_start`
- `:tool_execution_update`
- `:tool_execution_end`
- `:turn_end`
- `:agent_end`

When the underlying provider streams assistant deltas, `:message_update` includes an `assistant_message_event` with normalized sub-events such as:

- `:text_start`, `:text_delta`, `:text_end`
- `:thinking_start`, `:thinking_delta`, `:thinking_end`
- `:tool_call_start`, `:tool_call_delta`, `:tool_call_end`

## Async control, follow-up, and cancellation

`Agent` supports both synchronous and asynchronous use.

```ruby
agent.start("double 4")
agent.follow_up("double 5")
agent.wait_until_idle
```

Useful methods:

- `start(input)` - start asynchronously
- `prompt(input)` - run synchronously
- `continue_async` / `continue` - continue from the current conversation state
- `steer(input)` - inject messages into the active run before the next model turn
- `follow_up(input)` - queue the next user turn
- `cancel(reason = nil)` - cancel the active run
- `wait_until_idle` - join the active thread
- `reset!` - cancel, wait, and clear messages/state
- `busy?` - whether a run is active
- `last_error` - last assistant error message, if any

Cancellation is cooperative. `RubyPi::Cancellation::Token` is passed down into providers and tools, and `raise_if_cancelled!` is used to stop work cleanly.

## Models and providers

RubyPi separates model definitions from provider implementations.

### Model registry

Register a model with:

```ruby
RubyPi.register_model(
  RubyPi.model(
    id: "my-provider/my-model",
    provider: "my-provider",
    api: :openai_completions,
    base_url: "https://example.com/v1",
    input: ["text", "image"],
    compat: {
      max_tokens_field: "max_tokens",
      supports_parallel_tool_calls: true,
      supports_developer_role: false
    }
  )
)
```

A model record contains things like:

- `:id`
- `:provider`
- `:api`
- `:base_url`
- `:headers`
- `:input`
- `:max_tokens`
- `:compat`

### Built-in models

`RubyPi.bootstrap!` registers default models from `lib/ruby_pi/models/defaults.rb`:

- `openai/gpt-5.4`
- `openai/gpt-5.4-mini`
- `openai/gpt-4o-mini`
- `openrouter/anthropic/claude-3.7-sonnet`
- `groq/llama-3.3-70b-versatile`
- `local/openai-compatible`

### Provider registry

Providers are adapters keyed by API style, not by vendor name.

Built-in:

- `:openai_completions`

Register your own provider:

```ruby
class MyProvider < RubyPi::Providers::Base
  def stream(model:, context:, options:, cancellation:)
    # return a RubyPi::Stream of normalized events
  end
end

RubyPi.register_provider(:my_api, MyProvider.new)
```

## OpenAI-compatible adapter

The built-in provider in `lib/ruby_pi/providers/openai_completions.rb` targets `/chat/completions` style APIs over server-sent events.

It handles:

- system prompt injection
- user text and image content
- assistant text and tool calls
- tool result messages
- reasoning/thinking deltas when a backend emits them
- incremental tool-call argument assembly
- usage extraction
- final stop reason mapping
- auth headers and bearer tokens
- HTTP and streamed API errors
- cancellation during streaming

The tests in `test/openai_completions_adapter_test.rb` show that it correctly:

- reconstructs streamed text
- reconstructs streamed tool-call arguments
- preserves mixed content order
- turns HTTP/API failures into assistant error messages
- returns an aborted message on cancellation

### Auth resolution

`RubyPi::Auth.resolve` accepts:

- `api_key: "..."`
- `api_key: { api_key: "...", headers: { ... } }`
- `get_api_key: ->(provider) { ... }`
- provider-specific environment variables

Built-in env var lookup:

- `OPENAI_API_KEY`
- `OPENROUTER_API_KEY`
- `GROQ_API_KEY`
- `CEREBRAS_API_KEY`
- `XAI_API_KEY`

## Schemas and argument coercion

`RubyPi::SchemaValidator` validates tool arguments using a compact schema format similar to JSON Schema.

Supported shapes in the code include:

- `type: "object"`
- `type: "array"`
- scalar types: `string`, `integer`, `number`, `boolean`
- `properties`
- `required`
- `items`
- `enum`
- `const`
- `additionalProperties: false`

It also performs light coercion, for example:

- numeric strings to integers/numbers
- `"true"` / `"false"` to booleans
- enum matching by string form

The tests confirm that invalid shapes still fail cleanly, for example when a string field receives a hash.

## Tool authoring notes

A tool executor can be written in several forms. RubyPi adapts to the block signature.

Examples the implementation supports:

```ruby
RubyPi::Tool.define(name: "a", description: "...") { }
RubyPi::Tool.define(name: "b", description: "...") { |arguments| }
RubyPi::Tool.define(name: "c", description: "...") { |arguments, cancellation| }
RubyPi::Tool.define(name: "d", description: "...") { |tool_call_id, arguments, cancellation| }
RubyPi::Tool.define(name: "e", description: "...") { |tool_call_id, arguments, cancellation, on_update| }

RubyPi::Tool.define(name: "f", description: "...") do |arguments:, cancellation:|
end
```

If a tool yields partial updates through `on_update`, the agent loop emits `:tool_execution_update` events.

## Lower-level APIs

If you do not want the stateful `Agent` wrapper, you can work directly with `AgentLoop`:

```ruby
stream = RubyPi::AgentLoop.stream(
  prompts: [RubyPi::Messages.user("Hi")],
  context: {
    system_prompt: "You are helpful.",
    messages: [],
    tools: []
  },
  config: {
    model: model,
    convert_to_llm: ->(messages) { messages },
    provider_registry: RubyPi.providers
  }
)

stream.each do |event|
  p event
end

p stream.result
```

You can also use the lower-level building blocks directly:

- `RubyPi::Http::Client` for POST and streaming POST
- `RubyPi::Http::SseParser` for SSE chunks
- `RubyPi::Stream` for producer/consumer event streams

## Development

Install dependencies and run the local checks with:

```bash
./bin/ci
```

Or run the steps individually:

```bash
./bin/test
./bin/build
```

`bin/build` writes the gem to `pkg/`.

## What the tests tell you about intended behavior

The test suite is a good guide to the public contract.

- `test/agent_test.rb` covers the full agent loop, hooks, reset behavior, and parallel tool ordering
- `test/http_client_test.rb` covers JSON posts, stream chunking, and cancellation while waiting for data
- `test/openai_completions_adapter_test.rb` covers OpenAI-compatible streaming normalization and integration with tools
- `test/sse_parser_test.rb` covers SSE framing, keepalive handling, split chunks, and final flush behavior

## Minimal end-to-end example

```ruby
require "ruby_pi"

tool = RubyPi::Tool.define(
  name: "double",
  description: "Double a number",
  schema: {
    type: "object",
    properties: { value: { type: "integer" } },
    required: ["value"],
    additionalProperties: false
  }
) do |arguments, _cancellation|
  {
    content: [RubyPi::Messages.text((arguments["value"] * 2).to_s)],
    details: {}
  }
end

model = RubyPi.models.fetch("openai", "openai/gpt-4o-mini")

agent = RubyPi::Agent.new(
  model: model,
  system_prompt: "You are a concise math assistant. Use tools when useful.",
  tools: [tool],
  api_key: ENV["OPENAI_API_KEY"]
)

agent.prompt("double 21")

agent.messages.each do |message|
  p message
end
```

## Summary

RubyPi is a compact Ruby agent runtime built around a normalized message format, a looping tool-execution engine, and an OpenAI-compatible streaming provider. If you want a small, inspectable codebase for building Ruby agents that can stream responses, call tools, and continue multi-turn workflows, that is exactly what this repository implements.
