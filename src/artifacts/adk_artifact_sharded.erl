%% @doc Bounded exact-scope artifact adapter.
%%
%% Every exact application/user/session scope is assigned one supervised
%% adapter process. The default shard is `adk_artifact_ets'; selecting
%% `adk_artifact_fs' derives a deterministic, path-safe subroot for each scope.
-module(adk_artifact_sharded).
-behaviour(adk_artifact_service).

-export([start_link/1, stop/1, capabilities/1, status/1,
         put/5, put/6, get/4, get/5, list/2,
         list_names/3, list_versions/4, delete/4, delete/5]).

-define(DEFAULT_TIMEOUT_MS, 30000).

-spec start_link(map()) ->
    {ok, adk_scope_shard_router:handle()} | {error, term()}.
start_link(Config) when is_map(Config) ->
    Allowed = [adapter, adapter_config,
               max_active_scopes, max_router_queue],
    Unknown = lists:sort(maps:keys(maps:without(Allowed, Config))),
    Adapter = maps:get(adapter, Config, adk_artifact_ets),
    AdapterConfig = maps:get(adapter_config, Config, #{}),
    RouterOptions = maps:with(
                      [max_active_scopes, max_router_queue], Config),
    case {Unknown, is_atom(Adapter), is_map(AdapterConfig)} of
        {[], true, true} ->
            adk_scope_shard_router:start_link(
              artifact, Adapter, AdapterConfig, RouterOptions);
        {[_ | _], _, _} ->
            {error, {invalid_artifact_sharded_config,
                     {unknown_keys, Unknown}}};
        {[], false, _} ->
            {error, {invalid_artifact_sharded_config, adapter}};
        {[], _, false} ->
            {error, {invalid_artifact_sharded_config, adapter_config}}
    end;
start_link(_Config) ->
    {error, invalid_artifact_sharded_config}.

-spec stop(term()) -> ok | {error, term()}.
stop(Handle) ->
    adk_scope_shard_router:stop(Handle).

-spec capabilities(term()) -> {ok, map()} | {error, term()}.
capabilities(Handle) ->
    adk_scope_shard_router:capabilities(Handle).

-spec status(term()) -> {ok, map()} | {error, term()}.
status(Handle) ->
    adk_scope_shard_router:status(Handle).

-spec put(term(), adk_artifact_service:scope(), binary(), binary(), map()) ->
    {ok, adk_artifact_service:artifact_meta()} | {error, term()}.
put(Handle, Scope, Name, Data, Options) ->
    put(Handle, Scope, Name, Data, Options, #{}).

-spec put(term(), adk_artifact_service:scope(), binary(), binary(), map(),
          adk_artifact_service:call_options()) ->
    {ok, adk_artifact_service:artifact_meta()} | {error, term()}.
put(Handle, Scope, Name, Data, Options, CallOptions) ->
    deadline_call(
      Handle, Scope, CallOptions,
      fun(Adapter, Worker, Adjusted) ->
          Adapter:put(Worker, Scope, Name, Data, Options, Adjusted)
      end).

-spec get(term(), adk_artifact_service:scope(), binary(),
          adk_artifact_service:selector()) ->
    {ok, adk_artifact_service:artifact()} | {error, term()}.
get(Handle, Scope, Name, Selector) ->
    get(Handle, Scope, Name, Selector, #{}).

-spec get(term(), adk_artifact_service:scope(), binary(),
          adk_artifact_service:selector(),
          adk_artifact_service:call_options()) ->
    {ok, adk_artifact_service:artifact()} | {error, term()}.
get(Handle, Scope, Name, Selector, CallOptions) ->
    deadline_call(
      Handle, Scope, CallOptions,
      fun(Adapter, Worker, Adjusted) ->
          Adapter:get(Worker, Scope, Name, Selector, Adjusted)
      end).

-spec list(term(), adk_artifact_service:scope()) ->
    {ok, [adk_artifact_service:artifact_meta()]} | {error, term()}.
list(Handle, Scope) ->
    scoped_call(Handle, Scope,
                fun(Adapter, Worker) ->
                    Adapter:list(Worker, Scope)
                end).

-spec list_names(term(), adk_artifact_service:scope(), map()) ->
    {ok, adk_artifact_service:name_page()} | {error, term()}.
list_names(Handle, Scope, Options) ->
    scoped_call(Handle, Scope,
                fun(Adapter, Worker) ->
                    Adapter:list_names(Worker, Scope, Options)
                end).

-spec list_versions(term(), adk_artifact_service:scope(), binary(), map()) ->
    {ok, adk_artifact_service:version_page()} | {error, term()}.
list_versions(Handle, Scope, Name, Options) ->
    scoped_call(Handle, Scope,
                fun(Adapter, Worker) ->
                    Adapter:list_versions(Worker, Scope, Name, Options)
                end).

-spec delete(term(), adk_artifact_service:scope(), binary(),
             adk_artifact_service:delete_selector()) ->
    ok | {error, term()}.
delete(Handle, Scope, Name, Selector) ->
    delete(Handle, Scope, Name, Selector, #{}).

-spec delete(term(), adk_artifact_service:scope(), binary(),
             adk_artifact_service:delete_selector(),
             adk_artifact_service:call_options()) ->
    ok | {error, term()}.
delete(Handle, Scope, Name, Selector, CallOptions) ->
    deadline_call(
      Handle, Scope, CallOptions,
      fun(Adapter, Worker, Adjusted) ->
          Adapter:delete(Worker, Scope, Name, Selector, Adjusted)
      end).

deadline_call(Handle, Scope, CallOptions, Function) ->
    case adk_artifact_core:validate_scope(Scope) of
        ok ->
            case adk_artifact_core:validate_call_options(
                   CallOptions, ?DEFAULT_TIMEOUT_MS) of
                {ok, Timeout, Deadline} ->
                    case adk_scope_shard_router:resolve(
                           Handle, Scope, Timeout) of
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

scoped_call(Handle, Scope, Function) ->
    case adk_artifact_core:validate_scope(Scope) of
        ok ->
            case adk_scope_shard_router:resolve(
                   Handle, Scope, ?DEFAULT_TIMEOUT_MS) of
                {ok, Adapter, Worker} ->
                    safe_apply(fun() -> Function(Adapter, Worker) end);
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end.

remaining_timeout(Deadline) ->
    erlang:max(0, Deadline - erlang:monotonic_time(millisecond)).

safe_apply(Function) ->
    try Function() of
        Reply -> Reply
    catch
        _:_ -> {error, artifact_shard_adapter_failed}
    end.
