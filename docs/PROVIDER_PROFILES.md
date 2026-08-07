# Model provider profiles

Erlang ADK supports operator-owned model profiles as the recommended way to
select a vendor, model, endpoint, and credential. Public agent or Live-session
configuration contains only bounded binary profile and model aliases. It does
not contain a module name, raw model ID, URL, header map, or API key.

See [MODEL_SUPPORT.md](MODEL_SUPPORT.md) for adapter support tiers, the
evidence boundary, and recipes for Gemini/Gemma, Vertex AI, OpenAI, Claude,
Ollama, vLLM, LiteLLM Proxy, and transparent Apigee deployments.

This guide concerns `provider_profiles`, the model-provider registry. It is
separate from the OAuth/tool-authentication `auth_provider_profiles` setting
introduced in 0.6.

## Why profiles are the default boundary

A profile keeps deployment authority in application configuration while
leaving inference choices explicit:

- the operator chooses a pre-existing adapter atom and an endpoint preset,
  structured HTTPS endpoint, or the explicit keyless loopback policy;
- the operator maps public binary aliases to concrete provider model IDs;
- the operator chooses a credential source and authority/storage/billing
  options;
- a caller may choose only a configured profile, a configured model alias,
  and that adapter's allowlisted inference/runtime options; and
- binary caller values are never converted into module atoms.

Profiles are read from the `erlang_adk` application environment. Configure
them in a deployment-owned `sys.config` or before starting agents:

```erlang
Profiles = #{
  <<"openai-prod">> =>
      #{request_adapter => adk_llm_openai,
        endpoint => openai,
        models => #{<<"fast">> => <<"gpt-5-mini">>},
        credential => {env, "OPENAI_API_KEY"},
        request_options => #{store => false}},
  <<"anthropic-prod">> =>
      #{request_adapter => adk_llm_anthropic,
        endpoint => anthropic,
        models => #{<<"reasoning">> => <<"claude-sonnet-4-5">>},
        credential => {env, "ANTHROPIC_API_KEY"},
        request_options =>
            #{anthropic_version => <<"2023-06-01">>}}
},
ok = application:set_env(erlang_adk, provider_profiles, Profiles).
```

An agent then uses only aliases:

```erlang
{ok, Agent} = erlang_adk:spawn_agent(
    <<"Writer">>,
    #{provider => <<"openai-prod">>,
      model => <<"fast">>,
      instructions => <<"Write concise answers.">>,
      temperature => 0.2,
      max_tokens => 512},
    []),
{ok, Reply} = erlang_adk:prompt(Agent, <<"Explain supervision trees.">>),
ok = erlang_adk:stop_agent(Agent).
```

`provider` and `model` are binary aliases in this form. The earlier direct
module form, for example `#{provider => adk_llm_gemini, ...}`, remains a
trusted-code compatibility path. Do not construct that form from browser,
tenant, or other untrusted input.

Checked CLI JSON uses the same boundary. When a configured profile has the
same ID as a built-in CLI alias (`gemini`, `openai`, `anthropic`, or
`compatible`), the profile takes precedence. This makes the documented
`compatible` JSON selection usable without adding raw endpoints or secrets to
the file. With no matching profile, the native aliases keep their existing
fixed-origin compatibility behavior.

## Profile schema

Each entry under `provider_profiles` has a bounded binary identifier and the
following fields:

| Field | Meaning |
| --- | --- |
| `request_adapter` | Optional existing atom implementing request generation and streaming. |
| `live_adapter` | Optional existing atom implementing the Live provider contract. |
| `endpoint` | `gemini`, `openai`, `anthropic`, `vertex`, `local`, a structured custom HTTPS endpoint, or the exact `loopback_keyless` map below. |
| `models` | One or more binary aliases mapped to a concrete binary model ID or to `#{id => ModelId, capabilities => Map}`. |
| `credential` | `none`, `google_adc`, `{env, Name}`, `{application_env, App, Key}`, or `{literal, Binary}`. |
| `capabilities` | Optional bounded, secret-free profile/model metadata. It may narrow, but must not widen, adapter behavior. |
| `request_options` | Optional operator-locked adapter options described below. |

At least one of `request_adapter` and `live_adapter` is required. Profile and
model aliases use letters, digits, `.`, `_`, and `-`; they are not arbitrary
provider paths.

A custom endpoint is data, not a URL string:

```erlang
#{scheme => https,
  host => <<"models.example.com">>,
  port => 443,
  base_path => <<"/v1">>}
```

Ordinary custom endpoints are HTTPS only. Userinfo, query, fragment, control
characters, and `..` path segments are not accepted. Each adapter appends its
own fixed operation path, such as `/responses`, `/messages`, or
`/chat/completions`. Redirects are disabled, TLS peer and hostname verification
are mandatory for HTTPS, response sizes and deadlines are bounded, each
aggregate response-header or trailer block is capped at 64 KiB in both
synchronous and streaming Gun paths, and non-global resolved addresses are
rejected by default. A profile caller cannot enable private-address access or
replace the HTTP transport.

0.9.0 adds one separate HTTP exception for a keyless OpenAI-compatible server on
the same machine:

```erlang
#{scheme => http,
  host => <<"127.0.0.1">>,
  port => 11434,
  base_path => <<"/v1">>,
  policy => loopback_keyless}
```

The host must be the exact numeric loopback `127.0.0.1` or `::1`;
`localhost`, LAN/container addresses, wildcard/listen addresses, and arbitrary
private hosts are rejected. This endpoint requires
`request_adapter => adk_llm_compatible`, no Live adapter,
`credential => none`, and locked `request_options => #{auth_scheme => none}`.
Materialization adds an internal policy marker and private-host permission that
public callers cannot set. The compatible adapter rechecks those values and
the exact loopback HTTP URL before dispatch. Redirects remain disabled and the
transport remains pinned to the exact scheme and host.

The older `endpoint => local` atom remains a preset owned by a trusted custom
adapter; it does not authorize HTTP for `adk_llm_compatible` and is not an
alias for this policy map.

The bundled adapter/preset pairs are:

| Adapter | Required preset or endpoint |
| --- | --- |
| `adk_llm_gemini` | `gemini` or a structured HTTPS endpoint |
| `adk_llm_openai` | `openai` or a structured HTTPS endpoint |
| `adk_llm_anthropic` | `anthropic` or a structured HTTPS endpoint |
| `adk_llm_vertex` | `vertex` only; origin is derived from the full publisher-model resource |
| `adk_llm_compatible` | a structured HTTPS endpoint, or the exact keyless loopback map |
| `adk_live_gemini` | `gemini` only |
| `adk_live_openai` | `openai` only |

Bundled request adapters accept only these profile-level locked options:

| Adapter | `request_options` |
| --- | --- |
| `adk_llm_openai` | optional `organization`, `project`, and boolean `store` |
| `adk_llm_anthropic` | `anthropic_version` when the map is non-empty |
| `adk_llm_compatible` | optional empty map (defaults to bearer/auto), or `auth_scheme` plus an optional locked `response_format` mode |
| `adk_llm_gemini` | no profile request options in 0.8 |
| `adk_llm_vertex` | no profile request options in 0.9 |

Unknown fields fail profile validation; they are not forwarded to a provider.

Bundled Live transports have fixed verified-TLS origins. Custom Live
endpoints are therefore rejected; supporting one requires a separate trusted
adapter/transport contract rather than a caller-supplied WebSocket URL.

## Credential sources and generation consistency

Environment sources use strict uppercase names containing only `A-Z`, `0-9`,
and `_`, beginning with a letter or underscore. Examples are
`OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, and `GEMINI_API_KEY`.

`{application_env, App, Key}` is useful when a deployment secret manager has
already populated private application configuration. `{literal, Binary}` is
accepted at the trusted configuration boundary for tests or externally
protected release configuration, but its public profile projection is only
`#{source => literal}`. Prefer an environment or deployment-owned secret
adapter rather than committing a literal.

Resolution is generation-consistent: selecting the adapter, endpoint, and
model records an opaque HMAC snapshot of the exact raw profile. The credential
is resolved only if that profile generation still matches. A concurrent
profile replacement fails with `provider_profile_changed` instead of combining
old authority with a new credential source. Error values and public profile
projections never contain credential material.

`google_adc` is accepted only for `request_adapter => adk_llm_vertex` with the
`vertex` endpoint and no Live adapter. It resolves to a fresh OAuth bearer at
request time through the fixed, bounded
`gcloud auth application-default print-access-token --quiet` command. This is
the current local ADC bridge, not a claim of full authentication-library ADC
precedence or attached-service-account metadata support. Ordinary environment,
application-environment, and literal sources are treated as already-minted
OAuth access tokens for Vertex; the operator must rotate those before expiry.

For direct legacy native OpenAI and Anthropic configurations, the conventional
ambient environment key is read only for the exact official base URL. A custom
origin requires an explicit key. The OpenAI-compatible adapter has no single
official origin and always requires the key to be materialized by trusted
configuration when `auth_scheme` is not `none`. Profiles perform that
materialization without exposing the value to the public caller.

## Native OpenAI Responses profile

`adk_llm_openai` uses the native OpenAI Responses API. It supports bounded
one-shot and incremental SSE output, canonical text plus inline/referenced
image content, function calls with call IDs, parallel calls, and structured
JSON output.
OpenAI organization, project, and storage policy are operator-owned:

```erlang
#{<<"openai-prod">> =>
      #{request_adapter => adk_llm_openai,
        endpoint => openai,
        models =>
            #{<<"fast">> =>
                  #{id => <<"gpt-5-mini">>,
                    capabilities => #{structured_output => true}}},
        credential => {env, "OPENAI_API_KEY"},
        request_options =>
            #{organization => <<"org_operator_owned">>,
              project => <<"proj_operator_owned">>,
              store => false}}}
```

The caller may choose validated inference options such as `temperature`,
`top_p`, `max_tokens`/`max_output_tokens`, `parallel_tool_calls`, response
schema settings, content limits, and request bounds. It cannot replace
`organization`, `project`, `store`, the endpoint, model ID, credential,
headers, or transport.

Protocol reference: [OpenAI Responses API](https://platform.openai.com/docs/api-reference/responses).

## Native Anthropic Messages profile

`adk_llm_anthropic` uses the native Messages API with `x-api-key` and a locked
`anthropic-version`. It supports bounded one-shot and incremental SSE output,
text and supported image input, function tools and tool results, parallel tool
blocks, and structured JSON output through `output_config.format`:

```erlang
#{<<"anthropic-prod">> =>
      #{request_adapter => adk_llm_anthropic,
        endpoint => anthropic,
        models => #{<<"reasoning">> => <<"claude-sonnet-4-5">>},
        credential => {env, "ANTHROPIC_API_KEY"},
        request_options =>
            #{anthropic_version => <<"2023-06-01">>}}}
```

The caller may choose bounded `max_tokens` with a minimum of one,
sampling/stop options,
`tool_choice`, content limits, and request bounds. It cannot select an API
version, endpoint, credential, header, or transport.

Protocol references: [Messages API](https://platform.claude.com/docs/en/api/messages/create),
[streaming](https://platform.claude.com/docs/en/build-with-claude/streaming),
and [API versioning](https://platform.claude.com/docs/en/api/versioning).

## Native Vertex AI GenerateContent profile

`adk_llm_vertex` accepts only a complete v1 Google publisher-model resource and
derives the fixed Vertex HTTPS origin from its location:

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

The supported caller options are the bounded sampling/token/stop settings,
response MIME type/schema, safety settings, content and stream-event limits,
and request/response bounds implemented by the adapter. `candidate_count`,
thinking controls, built-in tools, cached content, Live configuration, custom
origins, partner publishers, endpoint resources, token-provider handles, and
transport overrides are rejected. Capability metadata can narrow this ceiling
but cannot raise it.

The stream method uses the adapter-owned `alt=sse` query after the ordinary
query-free path validation; general model HTTP paths still reject caller query
or fragment data. This profile recipe and its deterministic tests are not a
remote Vertex verification result.

Protocol references: [Vertex AI GenerateContent](https://cloud.google.com/vertex-ai/generative-ai/docs/model-reference/inference)
and [Application Default Credentials](https://cloud.google.com/docs/authentication/application-default-credentials).

## OpenAI-compatible profile

`adk_llm_compatible` targets a deliberately narrow Chat Completions shape. It
does not mean arbitrary HTTP compatibility. The operator normally owns a
structured HTTPS base endpoint and one of three authentication modes:
`bearer`, `x_api_key`, or `none`. The only supported HTTP form is the distinct
keyless numeric-loopback policy above.

```erlang
#{<<"vendor-prod">> =>
      #{request_adapter => adk_llm_compatible,
        endpoint =>
            #{scheme => https,
              host => <<"api.vendor.example">>,
              port => 443,
              base_path => <<"/v1">>},
        models =>
            #{<<"chat">> =>
                  #{id => <<"vendor-chat-model">>,
                    capabilities => #{structured_output => false}}},
        credential => {env, "VENDOR_API_KEY"},
        request_options =>
            #{auth_scheme => bearer,
              response_format => unsupported}}}
```

Use `credential => none` with `auth_scheme => none`; otherwise configure a
credential. The caller cannot change the scheme or the operator's
`response_format` mode. Valid locked modes are `auto`, `text`, `json_object`,
`json_schema`, and `unsupported`; choose `unsupported` for a vendor that does
not implement Chat Completions structured output. Do not claim audio, response
formats, tool-call streaming, usage fields, or other optional vendor behavior
until the target service has been tested against the deterministic codec
contract and an opt-in provider smoke test.

For local development with Ollama or vLLM, configure the server's
OpenAI-compatible Chat Completions surface and use the `loopback_keyless` map;
the adapter appends `/chat/completions` to `base_path`. This is deterministic
profile/transport support, not proof that a particular server/model implements
optional tools, multimodal input, structured output, or streaming details.
Use an ordinary authenticated HTTPS profile for LiteLLM Proxy or other remote
gateways. See [MODEL_SUPPORT.md](MODEL_SUPPORT.md) for complete recipes and
the evidence tiers.

## Gemini and OpenAI Live profiles

Both Live paths use one independently supervised Erlang process per session,
bounded ingress and subscriber credit, explicit ownership, and a server-side
credential broker. A browser or other public caller selects only aliases and
behavior options validated by the chosen Live adapter.

```erlang
LiveProfiles = #{
  <<"gemini-live">> =>
      #{live_adapter => adk_live_gemini,
        endpoint => gemini,
        models =>
            #{<<"voice">> => <<"gemini-3.1-flash-live-preview">>},
        credential => {env, "GEMINI_API_KEY"},
        capabilities => #{live => true}},
  <<"openai-live">> =>
      #{live_adapter => adk_live_openai,
        endpoint => openai,
        models => #{<<"voice">> => <<"gpt-realtime-2.1">>},
        credential => {env, "OPENAI_API_KEY"},
        capabilities => #{live => true}}
},
ok = application:set_env(erlang_adk, provider_profiles, LiveProfiles).
```

Start an OpenAI Realtime session without placing the key or transport module
in the session request:

```erlang
Principal = <<"user-42">>,
{ok, Session} = erlang_adk:start_live_session(
    <<"voice-session-42">>, Principal,
    #{provider => <<"openai-live">>,
      provider_config =>
          #{model => <<"voice">>,
            response_modalities => [audio],
            input_audio_transcription => true,
            automatic_activity_detection => true},
      max_ingress_messages => 64,
      max_ingress_bytes => 4194304}),
{ok, Status} = erlang_adk:live_status(Session, Principal),
24000 = maps:get(input_audio_sample_rate, Status).
```

Profile-selected Live callers may tune only the bounded transport deadlines,
flow/frame limits, and (for OpenAI) `safety_identifier` allowlisted by the
session. API keys and credential handles, model/endpoint/transport, CA/TLS
options, arbitrary headers, and OpenAI organization/project values are
rejected.

Gemini Live reports 16 kHz PCM s16le mono input; OpenAI Realtime reports
24 kHz. The owner-bound voice bridge reads this trusted value from session
status and sends an unsequenced format frame before accepting browser audio,
so a Phoenix client can resample to the negotiated input rate. Callers cannot
override it. Both currently emit native 24 kHz PCM audio events.

OpenAI Realtime implements GA WebSocket session setup, text/audio/image input,
text/audio output, transcription, function-call results, manual or server
activity detection, interruption, usage/rate-limit events, and ordered
multi-frame actions. Once a multi-frame action begins sending, its frames stay
contiguous even if a later priority action is admitted. It does not claim
provider session resumption. Gemini Live retains its existing resumption and
context-compression behavior.

Protocol references: [OpenAI Realtime over WebSocket](https://developers.openai.com/api/docs/guides/realtime-websocket),
[Realtime conversations](https://developers.openai.com/api/docs/guides/realtime-conversations),
and [Gemini Live](https://ai.google.dev/api/live).

## Authority and lifecycle checklist

- Build profiles only from trusted deployment configuration. Never merge a
  browser map into a profile.
- Give callers binary aliases, not adapter atoms or concrete model IDs.
- Keep endpoint, API-version, authentication, storage/billing headers, and
  credential sources operator-owned. OpenAI Realtime's bounded
  `safety_identifier` remains an allowlisted per-request semantic field, not an
  arbitrary header-map escape hatch.
- Use `loopback_keyless` only for a same-machine, intentionally unauthenticated
  compatible server. It is not a general private-network or development TLS
  bypass.
- Use separate profile IDs when tenant, region, billing project, retention,
  or capability policy differs.
- Validate all profiles at startup with `adk_provider_registry:profiles/0`
  and fail deployment if it returns an error.
- Rotate an environment/application secret without changing aliases. Replace
  profile authority atomically; in-flight selection against a different
  generation fails closed.
- Treat capability metadata as a narrowing declaration, not proof that a
  remote deployment supports a feature. Adapter implementation and live
  provider evidence remain the ceiling.
- Record deterministic codec/transport results separately from billable
  provider results. A missing key, skip, quota response, or provider error is
  not a passing integration test.
