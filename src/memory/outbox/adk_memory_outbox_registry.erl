%% @doc Runtime-only registry and resolver for memory-outbox adapters.
%%
%% Stable identities are durable; service handles are deliberately held only
%% in this process.  Operators can re-register a restarted adapter without
%% rewriting pending jobs.
-module(adk_memory_outbox_registry).
-behaviour(gen_server).
-behaviour(adk_memory_outbox_resolver).

-export([start_link/0, start_link/1, child_spec/1,
         register/3, unregister/2, resolve/3]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

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

init(Opts) ->
    Allowed = [name, max_entries],
    case maps:keys(maps:without(Allowed, Opts)) of
        [] ->
            Max = maps:get(max_entries, Opts, 128),
            case is_integer(Max) andalso Max > 0 andalso Max =< 10000 of
                true -> {ok, #state{max_entries = Max}};
                false -> {stop, invalid_memory_outbox_registry_capacity}
            end;
        Unknown -> {stop, {invalid_memory_outbox_registry_options,
                           {unknown_keys, lists:sort(Unknown)}}}
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
handle_call(_Request, _From, State) ->
    {reply, {error, unsupported_memory_outbox_registry_operation}, State}.

handle_cast(_Message, State) -> {noreply, State}.
handle_info(_Message, State) -> {noreply, State}.
terminate(_Reason, _State) -> ok.
code_change(_OldVersion, State, _Extra) -> {ok, State}.

safe_call(Registry, Request) ->
    try gen_server:call(Registry, Request, 5000) of
        Reply -> Reply
    catch
        exit:{noproc, _} -> {error, memory_outbox_resolver_unavailable};
        exit:{timeout, _} -> {error, memory_outbox_resolver_timeout};
        exit:Reason -> {error, {memory_outbox_resolver_down, Reason}}
    end.
