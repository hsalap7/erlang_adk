%% @doc Bounded exact-user-scope version-2 memory adapter.
%%
%% Each `{user, App, User}' principal is assigned one supervised adapter
%% process. The default is volatile ETS; `adk_memory_mnesia' may be selected
%% for durable storage while retaining independent per-scope call execution.
-module(adk_memory_sharded).
-behaviour(adk_memory_service).

-export([start_link/1, stop/1, capabilities/1, status/1,
         add_entry/4, add_entry/5,
         add_events/5, add_events/6,
         add_session_to_memory/5,
         search/4, search/5,
         delete_entry/3, delete_entry/4,
         delete_session/3, delete_session/4,
         delete_user/2, delete_user/3]).

-define(DEFAULT_TIMEOUT_MS, 5000).

-spec start_link(map()) ->
    {ok, adk_scope_shard_router:handle()} | {error, term()}.
start_link(Config) when is_map(Config) ->
    Allowed = [adapter, adapter_config,
               max_active_scopes, max_router_queue],
    Unknown = lists:sort(maps:keys(maps:without(Allowed, Config))),
    Adapter = maps:get(adapter, Config, adk_memory_ets),
    AdapterConfig = maps:get(adapter_config, Config, #{}),
    RouterOptions = maps:with(
                      [max_active_scopes, max_router_queue], Config),
    case {Unknown, is_atom(Adapter), is_map(AdapterConfig)} of
        {[], true, true} ->
            adk_scope_shard_router:start_link(
              memory, Adapter, AdapterConfig, RouterOptions);
        {[_ | _], _, _} ->
            {error, {invalid_memory_sharded_config,
                     {unknown_keys, Unknown}}};
        {[], false, _} ->
            {error, {invalid_memory_sharded_config, adapter}};
        {[], _, false} ->
            {error, {invalid_memory_sharded_config, adapter_config}}
    end;
start_link(_Config) ->
    {error, invalid_memory_sharded_config}.

-spec stop(term()) -> ok | {error, term()}.
stop(Handle) ->
    adk_scope_shard_router:stop(Handle).

-spec capabilities(term()) -> map() | {error, term()}.
capabilities(Handle) ->
    case adk_scope_shard_router:capabilities(Handle) of
        {ok, Capabilities} -> Capabilities;
        {error, _} = Error -> Error
    end.

-spec status(term()) -> {ok, map()} | {error, term()}.
status(Handle) ->
    adk_scope_shard_router:status(Handle).

-spec add_entry(term(), adk_memory_service:scope(),
                adk_memory_service:entry_input(), map()) ->
    {ok, adk_memory_service:entry()} | {error, term()}.
add_entry(Handle, Scope, Input, Options) ->
    add_entry(Handle, Scope, Input, Options, #{}).

-spec add_entry(term(), adk_memory_service:scope(),
                adk_memory_service:entry_input(), map(),
                adk_memory_service:call_options()) ->
    {ok, adk_memory_service:entry()} | {error, term()}.
add_entry(Handle, Scope, Input, Options, CallOptions) ->
    deadline_call(
      Handle, Scope, CallOptions,
      fun(Adapter, Worker, Adjusted) ->
          Adapter:add_entry(Worker, Scope, Input, Options, Adjusted)
      end).

-spec add_events(term(), adk_memory_service:scope(), binary(),
                 [adk_event:event()], map()) ->
    {ok, adk_memory_service:ingest_result()} | {error, term()}.
add_events(Handle, Scope, SessionId, Events, Options) ->
    add_events(Handle, Scope, SessionId, Events, Options, #{}).

-spec add_events(term(), adk_memory_service:scope(), binary(),
                 [adk_event:event()], map(),
                 adk_memory_service:call_options()) ->
    {ok, adk_memory_service:ingest_result()} | {error, term()}.
add_events(Handle, Scope, SessionId, Events, Options, CallOptions) ->
    deadline_call(
      Handle, Scope, CallOptions,
      fun(Adapter, Worker, Adjusted) ->
          Adapter:add_events(Worker, Scope, SessionId, Events,
                             Options, Adjusted)
      end).

-spec add_session_to_memory(term(), adk_memory_service:scope(), binary(),
                            [adk_event:event()], map()) ->
    {ok, adk_memory_service:ingest_result()} | {error, term()}.
add_session_to_memory(Handle, Scope, SessionId, Events, Options) ->
    add_events(Handle, Scope, SessionId, Events, Options).

-spec search(term(), adk_memory_service:scope(),
             adk_memory_service:query(), map()) ->
    {ok, [adk_memory_service:hit()]} | {error, term()}.
search(Handle, Scope, Query, Options) ->
    search(Handle, Scope, Query, Options, #{}).

-spec search(term(), adk_memory_service:scope(),
             adk_memory_service:query(), map(),
             adk_memory_service:call_options()) ->
    {ok, [adk_memory_service:hit()]} | {error, term()}.
search(Handle, Scope, Query, Options, CallOptions) ->
    deadline_call(
      Handle, Scope, CallOptions,
      fun(Adapter, Worker, Adjusted) ->
          Adapter:search(Worker, Scope, Query, Options, Adjusted)
      end).

-spec delete_entry(term(), adk_memory_service:scope(), binary()) ->
    ok | {error, term()}.
delete_entry(Handle, Scope, Id) ->
    delete_entry(Handle, Scope, Id, #{}).

-spec delete_entry(term(), adk_memory_service:scope(), binary(),
                   adk_memory_service:call_options()) ->
    ok | {error, term()}.
delete_entry(Handle, Scope, Id, CallOptions) ->
    deadline_call(
      Handle, Scope, CallOptions,
      fun(Adapter, Worker, Adjusted) ->
          Adapter:delete_entry(Worker, Scope, Id, Adjusted)
      end).

-spec delete_session(term(), adk_memory_service:scope(), binary()) ->
    ok | {error, term()}.
delete_session(Handle, Scope, SessionId) ->
    delete_session(Handle, Scope, SessionId, #{}).

-spec delete_session(term(), adk_memory_service:scope(), binary(),
                     adk_memory_service:call_options()) ->
    ok | {error, term()}.
delete_session(Handle, Scope, SessionId, CallOptions) ->
    deadline_call(
      Handle, Scope, CallOptions,
      fun(Adapter, Worker, Adjusted) ->
          Adapter:delete_session(Worker, Scope, SessionId, Adjusted)
      end).

-spec delete_user(term(), adk_memory_service:scope()) ->
    ok | {error, term()}.
delete_user(Handle, Scope) ->
    delete_user(Handle, Scope, #{}).

-spec delete_user(term(), adk_memory_service:scope(),
                  adk_memory_service:call_options()) ->
    ok | {error, term()}.
delete_user(Handle, Scope, CallOptions) ->
    deadline_call(
      Handle, Scope, CallOptions,
      fun(Adapter, Worker, Adjusted) ->
          Adapter:delete_user(Worker, Scope, Adjusted)
      end).

deadline_call(Handle, Scope, CallOptions, Function) ->
    case adk_memory_contract:validate_scope(Scope) of
        {ok, CanonicalScope} ->
            case validate_call_options(CallOptions) of
                {ok, Timeout, Deadline} ->
                    case adk_scope_shard_router:resolve(
                           Handle, CanonicalScope, Timeout) of
                        {ok, Adapter, Worker} ->
                            case remaining_timeout(Deadline) of
                                0 -> {error, timeout};
                                Remaining ->
                                    safe_apply(
                                      fun() ->
                                          Function(Adapter, Worker,
                                                   #{timeout_ms => Remaining})
                                      end)
                            end;
                        {error, _} = Error -> Error
                    end;
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end.

validate_call_options(CallOptions) when is_map(CallOptions) ->
    Unknown = lists:sort(
                maps:keys(maps:without([timeout_ms], CallOptions))),
    Timeout = maps:get(timeout_ms, CallOptions, ?DEFAULT_TIMEOUT_MS),
    case {Unknown, is_integer(Timeout) andalso Timeout > 0 andalso
                   Timeout =< 60000} of
        {[], true} ->
            {ok, Timeout,
             erlang:monotonic_time(millisecond) + Timeout};
        {[_ | _], _} ->
            {error, {invalid_memory_call_options,
                     {unknown_keys, Unknown}}};
        {[], false} -> {error, invalid_memory_call_timeout}
    end;
validate_call_options(_CallOptions) ->
    {error, invalid_memory_call_options}.

remaining_timeout(Deadline) ->
    erlang:max(0, Deadline - erlang:monotonic_time(millisecond)).

safe_apply(Function) ->
    try Function() of
        Reply -> Reply
    catch
        _:_ -> {error, memory_shard_adapter_failed}
    end.
