# Model support and conformance

This document is the released 0.9.0 support matrix for model backends. It
separates implemented wire contracts from configuration recipes and from
remote-provider evidence. A model name by itself never establishes protocol
compatibility: the serving endpoint and the features it actually implements
are what select an adapter.

## Support tiers

| Tier | Meaning |
| --- | --- |
| Native adapter | Erlang ADK owns a bounded codec for the provider's native wire protocol, with deterministic request, response, stream, error, and transport tests. |
| Compatible, endpoint-verified | The deployment exposes the narrow Chat Completions contract used by `adk_llm_compatible`, and that exact endpoint/model combination has a recorded smoke result. Optional capabilities are narrowed to the observed behavior. |
| Profile recipe | The profile shape is supported and deterministically validated, but no remote or local-server result is recorded for that endpoint/model. This is not a compatibility claim. |
| Adapter required | The service changes the request schema, response/stream events, authentication shape, operation paths, or other semantics. It needs a dedicated trusted adapter and tests. |

Remote evidence is tracked separately because a fixture pass proves the ADK
side of a contract, not a vendor deployment. Across the recorded evidence
through the 0.9 release:

- Gemini REST and Live have deterministic coverage. Historical 0.7 paid runs
  exist, while the 0.8 Gemini REST attempt ended in an external credential
  rejection and no 0.8 paid Live pass was recorded.
- OpenAI Responses, Anthropic Messages, compatible Chat Completions, and
  OpenAI Realtime have deterministic coverage but no repository-recorded paid
  provider pass.
- Vertex AI GenerateContent has deterministic adapter/profile/transport
  coverage added for 0.9, but no repository-recorded remote provider pass.
- No compatible vendor, Ollama server, vLLM server, or LiteLLM Proxy has a
  blanket certification. Evidence must name the exact endpoint, model ID,
  options, date, and result without recording prompts, outputs, or secrets.

See [TESTING.md](TESTING.md) and [VERSION_0_9_0.md](VERSION_0_9_0.md) for the
released scope and recorded evidence, and [VERSION_0_8_0.md](VERSION_0_8_0.md)
for the recorded historical results.

## Current request adapters

| Backend contract | Adapter | Current implementation tier | Remote evidence |
| --- | --- | --- | --- |
| Google GenerateContent | `adk_llm_gemini` | Native adapter | Historical Gemini evidence only; consult `TESTING.md` before making a current claim. |
| Vertex AI Google publisher GenerateContent | `adk_llm_vertex` | Native adapter for the bounded v1 request subset | Deterministic only; no remote Vertex result recorded. |
| OpenAI Responses | `adk_llm_openai` | Native adapter | Deterministic only in the recorded 0.8 gate. |
| Anthropic Messages | `adk_llm_anthropic` | Native adapter | Deterministic only in the recorded 0.8 gate. |
| OpenAI-style Chat Completions over HTTPS | `adk_llm_compatible` | Profile recipe until each endpoint/model is verified | No endpoint-specific remote result recorded. |
| OpenAI-style Chat Completions on same-machine HTTP | `adk_llm_compatible` plus `loopback_keyless` | Deterministic profile/transport conformance | No real Ollama/vLLM server result recorded. |

The compatible adapter owns the `/chat/completions` operation path. It does
not mean arbitrary OpenAI API compatibility and does not route to the native
Responses adapter. Structured output, multimodal input, tools, usage fields,
and stream details vary among servers; narrow profile/model capabilities and
set locked `response_format => unsupported` until the target is tested.

## Native provider recipes

### Gemini and Gemma

Use `adk_llm_gemini` only when the deployment exposes the Google
GenerateContent contract:

```erlang
#{<<"gemini-prod">> =>
      #{request_adapter => adk_llm_gemini,
        endpoint => gemini,
        models => #{<<"chat">> => <<"configured-gemini-model-id">>},
        credential => {env, "GEMINI_API_KEY"}}}
```

Gemma is a model family, not a transport contract. Do not select the Gemini
adapter merely because a model is named Gemma. A Gemma deployment exposed by
an OpenAI-compatible server uses `adk_llm_compatible`; a deployment exposing a
different native contract needs the matching adapter. Record conformance for
that concrete serving stack.

### Vertex AI / Agent Platform publisher models

Use `adk_llm_vertex` for the bounded Vertex AI v1 Google publisher-model
GenerateContent surface. The model value is the complete operator-owned
resource, not a short model ID:

```erlang
#{<<"vertex-prod">> =>
      #{request_adapter => adk_llm_vertex,
        endpoint => vertex,
        models =>
            #{<<"chat">> =>
                  <<"projects/PROJECT_ID/locations/us-central1/",
                    "publishers/google/models/CONFIGURED_MODEL_ID">>},
        credential => google_adc}}
```

`global` derives `https://aiplatform.googleapis.com`; a validated regional
location derives `https://LOCATION-aiplatform.googleapis.com`. The adapter owns
the `/v1/{model}:generateContent` and
`/v1/{model}:streamGenerateContent?alt=sse` paths, OAuth bearer header,
redirect policy, and exact HTTPS host allowlist. A profile caller cannot replace
the project, location, publisher, model resource, origin, path, headers, ADC
provider, or HTTP transport.

The `google_adc` source is currently a local, bounded bridge to the fixed
`gcloud auth application-default print-access-token --quiet` command. It does
not yet claim the complete Google authentication-library ADC precedence across
metadata servers, attached service accounts, or direct credential-file parsing.
An `{env, "VERTEX_ACCESS_TOKEN"}` or other ordinary profile credential source
may hold an already-minted OAuth token, but its refresh/rotation then belongs to
the operator.

The implemented capability ceiling covers one-shot and SSE
GenerateContent, canonical content, function calls, supported generation/safety
settings, and structured output. It does not claim Live, cached content,
built-in Search, thinking controls, multiple candidates, tuned endpoints,
partner publishers, Interactions, model discovery, or remote conformance.
See Google's [GenerateContent REST reference](https://cloud.google.com/vertex-ai/generative-ai/docs/model-reference/inference)
and [Application Default Credentials guide](https://cloud.google.com/docs/authentication/application-default-credentials).

### OpenAI

Use the native Responses adapter for an OpenAI Responses endpoint:

```erlang
#{<<"openai-prod">> =>
      #{request_adapter => adk_llm_openai,
        endpoint => openai,
        models => #{<<"chat">> => <<"configured-openai-model-id">>},
        credential => {env, "OPENAI_API_KEY"},
        request_options => #{store => false}}}
```

An OpenAI-compatible Chat Completions service is a different contract and
uses `adk_llm_compatible`, even if its model ID resembles an OpenAI model.

### Claude

Use the native Anthropic Messages adapter for a Claude deployment exposing
that API:

```erlang
#{<<"claude-prod">> =>
      #{request_adapter => adk_llm_anthropic,
        endpoint => anthropic,
        models => #{<<"reasoning">> => <<"configured-claude-model-id">>},
        credential => {env, "ANTHROPIC_API_KEY"},
        request_options =>
            #{anthropic_version => <<"2023-06-01">>}}}
```

Gate optional behavior with the concrete model/deployment evidence rather
than inferring it from the Claude family name.

## Compatible gateway and local-server recipes

### Ollama on the same machine

When Ollama is configured to expose its OpenAI-compatible `/v1` surface, use
the explicit loopback-only profile:

```erlang
#{<<"ollama-local">> =>
      #{request_adapter => adk_llm_compatible,
        endpoint =>
            #{scheme => http,
              host => <<"127.0.0.1">>,
              port => 11434,
              base_path => <<"/v1">>,
              policy => loopback_keyless},
        models => #{<<"chat">> => <<"configured-ollama-model">>},
        credential => none,
        request_options =>
            #{auth_scheme => none,
              response_format => unsupported}}}
```

This is a profile recipe, not evidence that every Ollama model implements the
adapter's optional tool, multimodal, or response-format features.

### vLLM on the same machine

For a vLLM process exposing OpenAI-compatible Chat Completions on loopback,
the profile is the same except for its operator-selected port and model ID:

```erlang
#{<<"vllm-local">> =>
      #{request_adapter => adk_llm_compatible,
        endpoint =>
            #{scheme => http,
              host => <<"127.0.0.1">>,
              port => 8000,
              base_path => <<"/v1">>,
              policy => loopback_keyless},
        models => #{<<"chat">> => <<"configured-vllm-model">>},
        credential => none,
        request_options =>
            #{auth_scheme => none,
              response_format => unsupported}}}
```

If vLLM is on another host, do not use the local exception. Put it behind a
verified HTTPS origin and use the ordinary structured compatible endpoint.

### LiteLLM Proxy

Treat a shared or remote LiteLLM Proxy as an authenticated HTTPS compatible
deployment:

```erlang
#{<<"litellm-prod">> =>
      #{request_adapter => adk_llm_compatible,
        endpoint =>
            #{scheme => https,
              host => <<"llm-gateway.example.com">>,
              port => 443,
              base_path => <<"/v1">>},
        models => #{<<"chat">> => <<"operator-configured-route">>},
        credential => {env, "LITELLM_PROXY_KEY"},
        request_options =>
            #{auth_scheme => bearer,
              response_format => unsupported}}}
```

A same-machine, intentionally keyless development proxy may use the loopback
policy. A proxy on a private LAN address may not: the exception accepts only
numeric `127.0.0.1` or `::1` and cannot be enabled by a profile caller.

### Transparent Apigee pass-through

A transparent Apigee proxy can use the native adapter only when it preserves
that adapter's upstream operation path, request/response schema, stream
framing, and authentication headers. For example, a Responses pass-through
could use:

```erlang
#{<<"openai-apigee">> =>
      #{request_adapter => adk_llm_openai,
        endpoint =>
            #{scheme => https,
              host => <<"models-gateway.example.com">>,
              port => 443,
              base_path => <<"/openai/v1">>},
        models => #{<<"chat">> => <<"configured-openai-model-id">>},
        credential => {env, "OPENAI_API_KEY"},
        request_options => #{store => false}}}
```

The adapter appends `/responses`, so the proxy must expose
`/openai/v1/responses` unchanged. Use the analogous native Gemini or
Anthropic adapter only for transparent pass-through of those native wires. If
Apigee changes auth, paths, schemas, errors, or streaming, it is not
transparent and requires a dedicated adapter rather than a profile claim.

## Loopback policy invariants

The `loopback_keyless` endpoint is a distinct opt-in exception to the normal
HTTPS/private-address policy. Validation requires all of the following:

- the request adapter is exactly `adk_llm_compatible` and no Live adapter is
  configured;
- the endpoint uses `http`, an exact numeric host of `127.0.0.1` or `::1`, a
  bounded port, and a safe absolute base path;
- `credential => none` and locked `request_options => #{auth_scheme => none,
  ...}` are present;
- materialization supplies the private-host permission and internal policy
  marker; public callers cannot supply or override either; and
- the adapter revalidates the URL, keyless auth, absent API key, and private-
  host setting before any request. Redirects remain disabled and the
  transport remains pinned to the exact scheme and host.

Hostnames such as `localhost`, wildcard/listen addresses, LAN addresses,
container hostnames, Unix-socket shims, credentials, and Live transports are
not accepted by this policy. Use an ordinary verified HTTPS profile or a new
audited adapter for those cases.

## Native-adapter backlog

The 0.9.0 adapter set does not add native adapters for every model catalog. The
following deployment contracts still need separate design and evidence when
their native surfaces are required:

- Azure OpenAI or Azure AI deployment paths, API-version semantics, and Azure
  credential modes;
- Amazon Bedrock native/Converse requests and SigV4 signing;
- native Cohere, Mistral, or other vendor APIs that do not expose the exact
  compatible Chat Completions contract; and
- gateways that transform auth, paths, request/response schemas, errors, or
  stream events instead of transparently forwarding an implemented wire.

An exact, tested compatible surface may use a compatible profile without a
native adapter. Vendor-specific semantics should not be hidden behind a
blanket compatibility claim.

## Adding evidence for another model

1. Identify the actual serving API and select the native or compatible
   adapter from that wire contract, not from the model family name.
2. Start with conservative capability metadata and locked compatible response
   mode.
3. Run deterministic codec/profile/transport tests.
4. Run an explicit opt-in smoke against the exact endpoint and model. Record
   date, API surface, options, and pass/fail/skip separately from fixtures.
5. Promote a compatible deployment to endpoint-verified only for behavior
   actually observed. A different model, server version, route, or proxy
   remains a separate evidence target.
