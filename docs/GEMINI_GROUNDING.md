# Gemini Google Search grounding

Erlang ADK 0.3.0 supports Google Search as a Gemini `generateContent` built-in
tool. The implementation follows the provider's GenerateContent contract while
keeping Erlang agents, tools, and concurrency OTP-native.

## Configuration and request mapping

Use the top-level provider option:

```erlang
#{provider => adk_llm_gemini,
  model => <<"gemini-3.1-flash-lite">>,
  builtin_tools => [google_search]}
```

Only `[]` and `[google_search]` are accepted. Binary names, unknown names,
duplicates, and a non-list value fail local provider validation. The CLI JSON
form is `"builtin_tools": ["google_search"]`; it is converted through a fixed
allow-list and never creates atoms from untrusted input.

The REST request contains:

```erlang
#{<<"tools">> => [#{<<"googleSearch">> => #{}}]}
```

If ordinary model tools are also present, the list is:

```erlang
[#{<<"googleSearch">> => #{}},
 #{<<"functionDeclarations">> => FunctionDeclarations}]
```

Gemini decides whether a request needs Search. Enabling the tool therefore does
not guarantee that every successful candidate is grounded.

## Provider-result contract

Metadata-free calls keep the existing return terms exactly: `{ok, Output}`,
`{tool_calls, Calls}`, `ok` for a completed stream, or `{error, Reason}`.

When the selected candidate contains `groundingMetadata`, the adapter returns
the reserved and checked LLM result:

```erlang
{provider_result,
 #{version => 1,
   provider => <<"gemini">>,
   type => <<"google_search_grounding">>,
   outcome => {ok, Output} | {tool_calls, Calls} | streamed,
   metadata => GroundingMetadata}}
```

`adk_provider_result:decode/1` revalidates envelopes from providers or mutable
callbacks. It returns `{ok, Outcome, ProviderMetadata}` where the event-safe
metadata is:

```erlang
#{<<"schema_version">> => 1,
  <<"provider">> => <<"gemini">>,
  <<"type">> => <<"google_search_grounding">>,
  <<"metadata">> => GroundingMetadata}
```

The envelope must have the exact version-1 keys and a valid outcome. Metadata
must be a JSON map without Erlang-only coercions and its encoded size must not
exceed 262,144 bytes. Invalid UTF-8, non-JSON terms, malformed envelopes, and
oversized metadata are rejected. The adapter preserves unknown JSON fields so
new provider metadata is not silently lost.

## Agent, schema, event, and stream behavior

The agent unwraps the `outcome` before applying `output_schema`. Provider
metadata cannot make a valid model output fail merely because the envelope has
additional fields. The final or tool-call event receives:

```erlang
#{<<"provider_metadata">> => ProviderMetadata}
```

Runner revalidation after global callbacks preserves these immutable actions;
newly recomputed action keys win if a key intentionally collides. Session
backends consequently persist the same bounded JSON-safe structure that
`adk_event:encode/1` exposes.

Gemini streaming may send new grounding chunks in successive SSE frames while
indices refer to the combined response. Erlang ADK accumulates these list
fields in provider order:

- `groundingChunks`
- `groundingSupports`
- `webSearchQueries`
- `imageSearchQueries`

Other grounding fields use the latest frame value. The accumulated map is
size-checked after every grounded frame. The provider's stream result uses the
`streamed` outcome; the agent combines it with its already bounded text/content
accumulator, validates the output contract, and attaches the metadata to the
single final event. Without grounding metadata, the stream still returns the
legacy `ok` or `{tool_calls, Calls}` result.

The metadata is candidate-specific. One-shot generation uses the same first
candidate already selected for output. A tool-call candidate's metadata is
attached to that tool-call event rather than attributed to a later candidate.

The envelope is provider-discriminated, JSON-safe, and size-bounded, but the
individual `groundingMetadata` fields are not normalized into an Erlang-owned
schema. This is intentional: Gemini may add forward-compatible fields. A
consumer that depends on `groundingChunks`, `groundingSupports`, or index
relationships must validate those fields at its own boundary.

## UI safety

`searchEntryPoint.renderedContent` is provider-controlled HTML/CSS. It is
preserved as a JSON string because a client may need it to implement Google's
search-suggestion display requirements, but Erlang ADK never treats it as
trusted markup. The bundled developer console uses DOM `textContent` and
`JSON.stringify`, has no `innerHTML` sink, and applies a restrictive CSP.

Application UIs must not inject this value into the DOM unsanitized. If an app
chooses to render provider search suggestions, it owns sanitization, safe link
handling, CSP policy, and compliance with the current Google display terms.

## Deliberate non-goals in 0.3.0

- the Gemini Interactions API;
- URL Context, Google Maps grounding, and Enterprise Web Search;
- bidirectional Gemini Live grounding;
- automatically rewriting answer text to insert citations;
- fetching grounding URLs inside the Erlang adapter;
- executing or interpreting `searchEntryPoint` markup in the developer UI.

Primary provider references:

- [Grounding with Google Search](https://ai.google.dev/gemini-api/docs/generate-content/google-search)
- [Gemini GenerateContent API](https://ai.google.dev/api/generate-content)
- [Gemini 3.1 Flash-Lite model card](https://ai.google.dev/gemini-api/docs/models/gemini-3.1-flash-lite)
