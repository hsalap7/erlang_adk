# Artifact services

Erlang ADK exposes immutable, versioned artifacts through the
`adk_artifact_service` behaviour. A service handle is passed to a Runner as
`{Module, Handle}`; provider code never receives the underlying filesystem
path or ETS table.

## In-memory ETS

`adk_artifact_ets` is appropriate for tests and ephemeral nodes:

```erlang
{ok, ArtifactPid} = adk_artifact_ets:start_link(#{}),
ArtifactService = {adk_artifact_ets, ArtifactPid}.
```

It preserves immutable versions for the lifetime of the service process.

## Durable filesystem storage

`adk_artifact_fs` persists data and metadata below a dedicated root:

```erlang
{ok, ArtifactPid} = adk_artifact_fs:start_link(
    #{root => <<"/var/lib/my_app/adk-artifacts">>,
      max_artifact_bytes => 67108864}),
ArtifactService = {adk_artifact_fs, ArtifactPid},

Scope = {session, <<"my_app">>, <<"user-42">>, <<"session-7">>},
{ok, #{version := 1}} = adk_artifact_fs:put(
    ArtifactPid, Scope, <<"reports/summary.txt">>, <<"ready">>,
    #{mime_type => <<"text/plain">>,
      metadata => #{<<"source">> => <<"agent">>}}),
{ok, #{data := <<"ready">>}} = adk_artifact_fs:get(
    ArtifactPid, Scope, <<"reports/summary.txt">>, latest).
```

The configured root must be a real directory, not a symbolic link. Scope and
logical artifact names are SHA-256-addressed and never become path
components. Metadata is checked against the requested scope, name, and
version on every read; the stored size and digest are checked before content
is returned. Corruption therefore fails as `{error, corrupt_artifact}` rather
than returning untrusted bytes.

Each `put/5` first creates an exclusive durable version reservation. A crash
may leave a harmless reserved version, but a deleted or interrupted version
is never reused after restart. Multiple service processes using the same root
also allocate distinct versions. Applications should still supervise one
service per root so list/delete operations have a single owner.

The artifact directory is an application-owned trust boundary. Give it
least-privilege filesystem permissions, keep it outside a served document
root, and use an encrypted volume when artifact confidentiality requires it.
The adapter does not encrypt content itself and must not be used as a secret
store.

## Runner integration

Pass the validated service reference to `adk_runner:new/4`:

```erlang
Runner = adk_runner:new(
    AgentPid, <<"my_app">>, erlang_adk_session,
    #{artifact_svc => ArtifactService}).
```

Artifact instruction placeholders are resolved only from the exact
invocation scope, through a bounded service call. Large binary artifacts stay
out of normal model context unless an application explicitly loads or maps
them into a supported multimodal part.
