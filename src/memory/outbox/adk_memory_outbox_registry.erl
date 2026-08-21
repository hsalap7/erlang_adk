%% @doc Runtime-only registry and resolver for memory-outbox adapters.
%%
%% Stable identities are durable; service handles are deliberately held only
%% in this process.  Operators can re-register a restarted adapter without
%% rewriting pending jobs.
-module(adk_memory_outbox_registry).
-behaviour(gen_server).
-behaviour(adk_memory_outbox_resolver).

-export([start_link/0, start_link/1, child_spec/1,
         register/3, unregister/2, resolve/3, ready/1,
         claimable_identities/1, validate_options/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3, format_status/1]).

-record(state, {services = #{}, max_entries = 128}).

start_link() -> start_link(#{}).

start_link(Opts) when is_map(Opts) ->
    case maps:get(name, Opts, undefined) of
        undefined -> gen_server:start_link(?MODULE, Opts, []);
        Name when is_atom(Name) ->
            gen_server:start_link({local, Name}, ?MODULE, Opts, []);
        _ -> {error, invalid_memory_outbox_registry_name}
    end;
start_link(_) -> {error, invalid_memory_outbox_registry_options}.

child_spec(Opts) ->
    #{id => maps:get(name, Opts, ?MODULE),
      start => {?MODULE, start_link, [Opts]},
      restart => permanent,
      shutdown => 5000,
      type => worker,
      modules => [?MODULE]}.

register(Registry, {Module, StableId} = Identity,
         {Module, _Handle} = ServiceRef)
  when is_atom(Module), is_binary(StableId), byte_size(StableId) > 0,
       byte_size(StableId) =< 256 ->
    case adk_service_ref:validate(memory, ServiceRef) of
        {ok, ServiceRef} -> safe_call(Registry, {register, Identity, ServiceRef});
        {error, _} = Error -> Error
    end;
register(_Registry, {_Module, _StableId}, {_Other, _Handle}) ->
    {error, memory_outbox_adapter_module_mismatch};
register(_Registry, _Identity, _ServiceRef) ->
    {error, invalid_memory_outbox_registry_entry}.

unregister(Registry, {Module, StableId} = Identity)
  when is_atom(Module), is_binary(StableId), byte_size(StableId) > 0 ->
    safe_call(Registry, {unregister, Identity});
unregister(_Registry, _Identity) ->
    {error, invalid_memory_outbox_adapter_identity}.

%% adk_memory_outbox_resolver callback.
resolve(Module, StableId, Registry)
  when is_atom(Module), is_binary(StableId) ->
    safe_call(Registry, {resolve, {Module, StableId}});
resolve(_Module, _StableId, _Registry) ->
    {error, invalid_memory_outbox_adapter_identity}.

%% adk_memory_outbox_resolver readiness callback. The registry is deliberately
%% volatile, so an empty instance after startup/restart is not ready to resolve
%% durable identities and must gate processor claims.
ready(Registry) -> safe_call(Registry, ready).

claimable_identities(Registry) ->
    safe_call(Registry, claimable_identities).

validate_options(Opts) when is_map(Opts) ->
    Allowed = [name, max_entries],
    Name = maps:get(name, Opts, undefined),
    case {maps:keys(maps:without(Allowed, Opts)),
          Name =:= undefined orelse is_atom(Name)} of
        {[_ | _] = Unknown, _} ->
            {error, {invalid_memory_outbox_registry_options,
                     {unknown_keys, lists:sort(Unknown)}}};
        {[], false} ->
            {error, invalid_memory_outbox_registry_name};
        {[], true} ->
            Max = maps:get(max_entries, Opts, 128),
            case is_integer(Max) andalso Max > 0 andalso Max =< 10000 of
                true -> ok;
                false -> {error, invalid_memory_outbox_registry_capacity}
            end
    end;
validate_options(_) ->
    {error, invalid_memory_outbox_registry_options}.

init(Opts) ->
    case validate_options(Opts) of
        ok ->
            {ok, #state{max_entries = maps:get(max_entries, Opts, 128)}};
        {error, Reason} -> {stop, Reason}
    end.

handle_call({register, Identity, ServiceRef}, _From,
            #state{services = Services, max_entries = Max} = State) ->
    case maps:is_key(Identity, Services) orelse map_size(Services) < Max of
        true ->
            {reply, ok, State#state{services = Services#{Identity => ServiceRef}}};
        false -> {reply, {error, memory_outbox_registry_capacity_exceeded}, State}
    end;
handle_call({unregister, Identity}, _From,
            #state{services = Services} = State) ->
    {reply, ok, State#state{services = maps:remove(Identity, Services)}};
handle_call({resolve, Identity}, _From, #state{services = Services} = State) ->
    Reply = case maps:find(Identity, Services) of
        {ok, ServiceRef} -> {ok, ServiceRef};
        error -> {error, memory_outbox_adapter_unavailable}
    end,
    {reply, Reply, State};
handle_call(ready, _From, #state{services = Services} = State) ->
    Reply = case map_size(Services) of
        0 -> not_ready;
        _ -> ready
    end,
    {reply, Reply, State};
handle_call(claimable_identities, _From,
            #state{services = Services} = State) ->
    Identities = maps:from_list(
                   [{Identity, true} || Identity <- maps:keys(Services)]),
    {reply, {ok, Identities}, State};
handle_call(_Request, _From, State) ->
    {reply, {error, unsupported_memory_outbox_registry_operation}, State}.

handle_cast(_Message, State) -> {noreply, State}.
handle_info(_Message, State) -> {noreply, State}.
terminate(_Reason, _State) -> ok.
code_change(_OldVersion, State, _Extra) -> {ok, State}.

%% Opaque service handles can contain provider-owned runtime state. Never
%% expose them through sys:get_status or crash-status formatting.
format_status(Status) when is_map(Status) ->
    maps:map(
      fun(state, #state{services = Services, max_entries = Max}) ->
              #{registered_services => map_size(Services),
                max_entries => Max};
         (message, _Message) -> adk_secret_redactor:marker();
         (log, _Log) -> [];
         (reason, _Reason) -> adk_secret_redactor:marker();
         (_Key, _Value) -> adk_secret_redactor:marker()
      end, Status);
format_status(_Status) -> adk_secret_redactor:marker().

safe_call(Registry, Request) ->
    try gen_server:call(Registry, Request, 5000) of
        Reply -> Reply
    catch
        exit:{noproc, _} -> {error, memory_outbox_resolver_unavailable};
        exit:{timeout, _} -> {error, memory_outbox_resolver_timeout};
        exit:_Reason -> {error, memory_outbox_resolver_unavailable}
    end.
