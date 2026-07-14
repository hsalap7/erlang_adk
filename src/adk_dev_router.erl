%% @doc Cowboy route bundle for the opt-in local ADK developer platform.
-module(adk_dev_router).

-export([routes/1, routes_validated/1, compile/1, validate_config/1]).

-define(DEFAULT_MAX_BODY_BYTES, 65536).
-define(DEFAULT_MAX_FIELD_BYTES, 4096).
-define(DEFAULT_HEARTBEAT_MS, 15000).
-define(DEFAULT_SSE_MAX_EVENTS, 128).
-define(DEFAULT_SSE_MAX_BYTES, 1048576).
-define(DEFAULT_SSE_MAX_DURATION_MS, 300000).
-define(MAX_SSE_EVENTS, 10000).
-define(MAX_SSE_BYTES, 16777216).
-define(MAX_SSE_DURATION_MS, 3600000).
-define(DEFAULT_MAX_SESSION_RESULTS, 100).

-spec compile(map()) -> term().
compile(Config) ->
    cowboy_router:compile([{'_', routes(Config)}]).

-spec routes(map()) -> [term()].
routes(Config0) ->
    {ok, Config} = validate_config(Config0),
    route_list(Config).

%% @doc Build routes from the already-sanitized configuration returned by
%% validate_config/1.  The application HTTP owner uses this form so the raw
%% bearer token never has to be retained or reintroduced after validation.
-spec routes_validated(map()) -> [term()].
routes_validated(Config) ->
    case valid_sanitized_config(Config) of
        true -> route_list(Config);
        false -> erlang:error(invalid_dev_platform_config)
    end.

route_list(Config) ->
    [
        {"/dev", adk_dev_handler, Config#{endpoint => ui}},
        {"/dev/", adk_dev_handler, Config#{endpoint => ui}},
        {"/dev/v1/agents", adk_dev_handler, Config#{endpoint => agents}},
        {"/dev/v1/runs", adk_dev_handler, Config#{endpoint => runs}},
        {"/dev/v1/runs/:run_id/events", adk_dev_handler,
         Config#{endpoint => run_events}},
        {"/dev/v1/runs/:run_id/resume", adk_dev_handler,
         Config#{endpoint => run_resume}},
        {"/dev/v1/runs/:run_id", adk_dev_handler,
         Config#{endpoint => run}},
        {"/dev/v1/sessions/:app_name/:user_id",
         adk_dev_handler, Config#{endpoint => sessions}},
        {"/dev/v1/sessions/:app_name/:user_id/:session_id/state",
         adk_dev_handler, Config#{endpoint => session_state}},
        {"/dev/v1/sessions/:app_name/:user_id/:session_id",
         adk_dev_handler, Config#{endpoint => session}}
    ].

valid_sanitized_config(Config) when is_map(Config) ->
    Digest = maps:get(auth_token_digest, Config, undefined),
    MaxBody = maps:get(max_body_bytes, Config, undefined),
    MaxField = maps:get(max_field_bytes, Config, undefined),
    Heartbeat = maps:get(sse_heartbeat_ms, Config, undefined),
    SseMaxEvents = maps:get(sse_max_events, Config, undefined),
    SseMaxBytes = maps:get(sse_max_bytes, Config, undefined),
    SseMaxDuration = maps:get(sse_max_duration_ms, Config, undefined),
    MaxSessionResults = maps:get(max_session_results, Config, undefined),
    SessionService = maps:get(session_service, Config, undefined),
    is_binary(Digest) andalso byte_size(Digest) =:= 32 andalso
    is_integer(MaxBody) andalso MaxBody > 0 andalso
    is_integer(MaxField) andalso MaxField > 0 andalso MaxField =< MaxBody andalso
    is_integer(Heartbeat) andalso Heartbeat > 0 andalso
    is_integer(SseMaxEvents) andalso SseMaxEvents > 0 andalso
    SseMaxEvents =< ?MAX_SSE_EVENTS andalso
    is_integer(SseMaxBytes) andalso SseMaxBytes > 0 andalso
    SseMaxBytes =< ?MAX_SSE_BYTES andalso
    is_integer(SseMaxDuration) andalso SseMaxDuration > 0 andalso
    SseMaxDuration =< ?MAX_SSE_DURATION_MS andalso
    is_integer(MaxSessionResults) andalso MaxSessionResults > 0 andalso
    MaxSessionResults =< 1000 andalso is_atom(SessionService) andalso
    is_map(maps:get(runner_options, Config, undefined)) andalso
    is_map(maps:get(run_options, Config, undefined)) andalso
    not maps:is_key(auth_token, Config);
valid_sanitized_config(_Config) ->
    false.

-spec validate_config(map()) -> {ok, map()} | {error, term()}.
validate_config(Config) when is_map(Config) ->
    Token = maps:get(auth_token, Config, undefined),
    MaxBody = maps:get(max_body_bytes, Config, ?DEFAULT_MAX_BODY_BYTES),
    MaxField = maps:get(max_field_bytes, Config, ?DEFAULT_MAX_FIELD_BYTES),
    Heartbeat = maps:get(sse_heartbeat_ms, Config, ?DEFAULT_HEARTBEAT_MS),
    SseMaxEvents = maps:get(sse_max_events, Config,
                            ?DEFAULT_SSE_MAX_EVENTS),
    SseMaxBytes = maps:get(sse_max_bytes, Config, ?DEFAULT_SSE_MAX_BYTES),
    SseMaxDuration = maps:get(sse_max_duration_ms, Config,
                              ?DEFAULT_SSE_MAX_DURATION_MS),
    MaxSessionResults = maps:get(max_session_results, Config,
                                 ?DEFAULT_MAX_SESSION_RESULTS),
    SessionService = maps:get(session_service, Config,
                              erlang_adk_session),
    RunnerOptions = maps:get(runner_options, Config, #{}),
    RunOptions = maps:get(run_options, Config, #{}),
    case is_binary(Token) andalso byte_size(Token) >= 16 andalso
         is_integer(MaxBody) andalso MaxBody > 0 andalso
         is_integer(MaxField) andalso MaxField > 0 andalso
         MaxField =< MaxBody andalso
         is_integer(Heartbeat) andalso Heartbeat > 0 andalso
         is_integer(SseMaxEvents) andalso SseMaxEvents > 0 andalso
         SseMaxEvents =< ?MAX_SSE_EVENTS andalso
         is_integer(SseMaxBytes) andalso SseMaxBytes > 0 andalso
         SseMaxBytes =< ?MAX_SSE_BYTES andalso
         is_integer(SseMaxDuration) andalso SseMaxDuration > 0 andalso
         SseMaxDuration =< ?MAX_SSE_DURATION_MS andalso
         is_integer(MaxSessionResults) andalso MaxSessionResults > 0 andalso
         MaxSessionResults =< 1000 andalso
         is_atom(SessionService) andalso
         is_map(RunnerOptions) andalso is_map(RunOptions) of
        true ->
            %% Cowboy keeps route state for the listener lifetime. Retain only
            %% a fixed-size digest there so the bearer token cannot appear in
            %% supervisor status, crash reports, or route introspection.
            TokenDigest = crypto:hash(sha256, Token),
            SafeConfig = maps:remove(auth_token, Config),
            {ok, SafeConfig#{auth_token_digest => TokenDigest,
                         max_body_bytes => MaxBody,
                         max_field_bytes => MaxField,
                         sse_heartbeat_ms => Heartbeat,
                         sse_max_events => SseMaxEvents,
                         sse_max_bytes => SseMaxBytes,
                         sse_max_duration_ms => SseMaxDuration,
                         max_session_results => MaxSessionResults,
                         session_service => SessionService,
                         runner_options => RunnerOptions,
                         run_options => RunOptions}};
        false ->
            {error, invalid_dev_platform_config}
    end;
validate_config(_Config) ->
    {error, invalid_dev_platform_config}.
