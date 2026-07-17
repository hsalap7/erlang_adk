%% @doc Race-safe node-local ownership registry for Live voice bridges.
%%
%% A Live session may have many read-only subscribers, but only one process may
%% own its bidirectional browser voice path. Claims are constant-time and are
%% serialized only for admission; bridges for different sessions continue
%% independently in their own lightweight processes. Both the session and the
%% bridge are monitored so abnormal death cannot strand a lease.
-module(adk_live_voice_registry).
-behaviour(gen_server).

-export([start_link/0, child_spec/1, claim/2, release/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3, format_status/1]).

-define(CALL_TIMEOUT_MS, 5000).

-spec start_link() -> gen_server:start_ret().
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec child_spec(term()) -> supervisor:child_spec().
child_spec(_Options) ->
    #{id => ?MODULE,
      start => {?MODULE, start_link, []},
      restart => permanent,
      shutdown => 5000,
      type => worker,
      modules => [?MODULE]}.

-spec claim(pid(), pid()) -> ok | {error, term()}.
claim(Session, Bridge) when is_pid(Session), is_pid(Bridge) ->
    case Bridge =:= self() of
        false -> {error, not_live_voice_lease_owner};
        true ->
            case local_pid(Session) andalso local_pid(Bridge) of
                true -> safe_call({claim, Session, Bridge});
                false -> {error, invalid_live_voice_lease}
            end
    end;
claim(_Session, _Bridge) ->
    {error, invalid_live_voice_lease}.

-spec release(pid(), pid()) -> ok | {error, term()}.
release(Session, Bridge) when is_pid(Session), is_pid(Bridge) ->
    case Bridge =:= self() of
        false -> {error, not_live_voice_lease_owner};
        true ->
            case local_pid(Session) andalso local_pid(Bridge) of
                true -> safe_call({release, Session, Bridge});
                false -> {error, invalid_live_voice_lease}
            end
    end;
release(_Session, _Bridge) ->
    {error, invalid_live_voice_lease}.

init([]) ->
    process_flag(message_queue_data, off_heap),
    {ok, #{leases => #{}, refs => #{}}}.

handle_call({claim, Session, Bridge}, {Bridge, _Tag}, State)
  when is_pid(Session), is_pid(Bridge) ->
    case local_pid(Session) andalso local_pid(Bridge)
         andalso is_process_alive(Session) andalso is_process_alive(Bridge) of
        false ->
            {reply, {error, invalid_live_voice_lease}, State};
        true ->
            claim_live_session(Session, Bridge, State)
    end;
handle_call({claim, _Session, _Bridge}, _From, State) ->
    {reply, {error, not_live_voice_lease_owner}, State};
handle_call({release, Session, Bridge}, {Bridge, _Tag}, State)
  when is_pid(Session), is_pid(Bridge) ->
    case local_pid(Session) andalso local_pid(Bridge) of
        true -> {reply, ok, remove_exact(Session, Bridge, State)};
        false -> {reply, {error, invalid_live_voice_lease}, State}
    end;
handle_call({release, _Session, _Bridge}, _From, State) ->
    {reply, {error, not_live_voice_lease_owner}, State};
handle_call(_Request, _From, State) ->
    {reply, {error, invalid_live_voice_registry_call}, State}.

handle_cast(_Message, State) ->
    {noreply, State}.

handle_info({'DOWN', Ref, process, _Pid, _Reason},
            #{refs := Refs} = State) ->
    case maps:find(Ref, Refs) of
        {ok, Session} ->
            {noreply, remove_session(Session, State)};
        error ->
            {noreply, State}
    end;
handle_info(_Message, State) ->
    {noreply, State}.

terminate(_Reason, #{leases := Leases}) ->
    maps:foreach(
      fun(_Session, Lease) -> demonitor_lease(Lease) end, Leases),
    ok.

code_change(_OldVersion, State, _Extra) ->
    {ok, State}.

format_status(Status) ->
    maps:map(
      fun(state, #{leases := Leases}) ->
              #{lease_count => map_size(Leases)};
         (message, _Message) -> redacted;
         (_Key, Value) -> Value
      end, Status).

claim_live_session(Session, Bridge, #{leases := Leases} = State) ->
    case maps:get(Session, Leases, undefined) of
        undefined ->
            {reply, ok, add_lease(Session, Bridge, State)};
        #{bridge := Bridge} ->
            {reply, ok, State};
        #{bridge := Existing} ->
            case is_process_alive(Existing) of
                true ->
                    {reply,
                     {error, live_voice_bridge_already_attached}, State};
                false ->
                    Clean = remove_session(Session, State),
                    {reply, ok, add_lease(Session, Bridge, Clean)}
            end
    end.

add_lease(Session, Bridge, #{leases := Leases, refs := Refs} = State) ->
    SessionRef = erlang:monitor(process, Session),
    BridgeRef = erlang:monitor(process, Bridge),
    Lease = #{bridge => Bridge,
              session_ref => SessionRef,
              bridge_ref => BridgeRef},
    State#{leases => Leases#{Session => Lease},
           refs => Refs#{SessionRef => Session, BridgeRef => Session}}.

remove_exact(Session, Bridge, #{leases := Leases} = State) ->
    case maps:get(Session, Leases, undefined) of
        #{bridge := Bridge} -> remove_session(Session, State);
        _Other -> State
    end.

remove_session(Session, #{leases := Leases, refs := Refs} = State) ->
    case maps:take(Session, Leases) of
        error ->
            State;
        {Lease, Remaining} ->
            SessionRef = maps:get(session_ref, Lease),
            BridgeRef = maps:get(bridge_ref, Lease),
            demonitor_lease(Lease),
            State#{leases => Remaining,
                   refs => maps:remove(
                             BridgeRef, maps:remove(SessionRef, Refs))}
    end.

demonitor_lease(Lease) ->
    erlang:demonitor(maps:get(session_ref, Lease), [flush]),
    erlang:demonitor(maps:get(bridge_ref, Lease), [flush]).

safe_call(Request) ->
    try gen_server:call(?MODULE, Request, ?CALL_TIMEOUT_MS) of
        Reply -> Reply
    catch
        exit:{noproc, _} -> {error, live_voice_registry_unavailable};
        exit:{timeout, _} -> {error, live_voice_registry_timeout};
        exit:_ -> {error, live_voice_registry_unavailable}
    end.

local_pid(Pid) ->
    node(Pid) =:= node().
