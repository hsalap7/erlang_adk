-module(adk_memory_outbox_test_adapter).
-behaviour(gen_server).
-behaviour(adk_memory_service).

-export([start_link/1, stop/1, release/1, stats/1,
         capabilities/1, add_entry/4, add_events/5, add_events/6,
         add_session_to_memory/5, search/4, delete_entry/3,
         delete_session/3, delete_user/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-record(state, {test_pid,
                seen = #{},
                calls = 0,
                block_first = false}).

start_link(Opts) -> gen_server:start_link(?MODULE, Opts, []).
stop(Pid) -> gen_server:stop(Pid).
release(Pid) -> Pid ! release_memory_outbox_call, ok.
stats(Pid) -> gen_server:call(Pid, stats, 5000).

capabilities(Pid) -> gen_server:call(Pid, capabilities, 5000).
add_entry(_Pid, _Scope, _Input, _Opts) -> {error, unsupported_test_operation}.
add_events(Pid, Scope, SessionId, Events, Opts) ->
    add_events(Pid, Scope, SessionId, Events, Opts, #{}).
add_events(Pid, Scope, SessionId, Events, Opts, _CallOptions) ->
    gen_server:call(Pid, {add_events, Scope, SessionId, Events, Opts}, 5000).
add_session_to_memory(Pid, Scope, SessionId, Events, Opts) ->
    add_events(Pid, Scope, SessionId, Events, Opts).
search(_Pid, _Scope, _Query, _Opts) -> {ok, []}.
delete_entry(_Pid, _Scope, _Id) -> ok.
delete_session(_Pid, _Scope, _SessionId) -> ok.
delete_user(_Pid, _Scope) -> ok.

init(Opts) ->
    {ok, #state{test_pid = maps:get(test_pid, Opts, undefined),
                block_first = maps:get(block_first, Opts, false)}}.

handle_call(capabilities, _From, State) ->
    {reply, #{contract_version => 2,
              idempotent_ingestion => true,
              incremental_events => true}, State};
handle_call(stats, _From, State) ->
    {reply, #{calls => State#state.calls,
              unique_events => map_size(State#state.seen)}, State};
handle_call({add_events, Scope, SessionId, Events, #{}}, _From, State0) ->
    EventIds = [maps:get(<<"id">>, Event) || Event <- Events],
    {Seen, Added, Duplicates} = classify(EventIds, State0#state.seen, 0, 0),
    Call = State0#state.calls + 1,
    notify(State0#state.test_pid,
           {memory_outbox_adapter_committed, self(), Call, Scope,
            SessionId, EventIds, Added, Duplicates}),
    maybe_block(State0#state.block_first, Call),
    State = State0#state{seen = Seen, calls = Call},
    {reply, {ok, #{added => Added, duplicates => Duplicates, skipped => 0}},
     State};
handle_call(_Request, _From, State) ->
    {reply, {error, unsupported_test_operation}, State}.

handle_cast(_Message, State) -> {noreply, State}.
handle_info(_Message, State) -> {noreply, State}.
terminate(_Reason, _State) -> ok.
code_change(_OldVersion, State, _Extra) -> {ok, State}.

classify([], Seen, Added, Duplicates) -> {Seen, Added, Duplicates};
classify([Id | Rest], Seen, Added, Duplicates) ->
    case maps:is_key(Id, Seen) of
        true -> classify(Rest, Seen, Added, Duplicates + 1);
        false -> classify(Rest, Seen#{Id => true}, Added + 1, Duplicates)
    end.

maybe_block(true, 1) ->
    receive
        release_memory_outbox_call -> ok
    after 4000 -> ok
    end;
maybe_block(_, _) -> ok.

notify(Pid, Message) when is_pid(Pid) -> Pid ! Message;
notify(_, _) -> ok.
