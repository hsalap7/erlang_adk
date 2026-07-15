%% @doc Dynamic supervisor for server-owned Live sessions.
%%
%% Sensitive provider and transport configuration is handed to an empty child
%% after it starts, so API keys never enter supervisor child specifications.
-module(adk_live_session_sup).
-behaviour(supervisor).

-export([start_link/0, child_spec/1, start_session/3]).
-export([init/1]).

-define(SERVER, ?MODULE).
-define(DEFAULT_SESSION_LIMIT, 1024).
-define(MAX_SESSION_LIMIT, 16384).

-spec start_link() -> supervisor:startlink_ret().
start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

-spec child_spec(term()) -> supervisor:child_spec().
child_spec(_Options) ->
    #{id => ?MODULE,
      start => {?MODULE, start_link, []},
      restart => permanent,
      shutdown => infinity,
      type => supervisor,
      modules => [?MODULE]}.

-spec start_session(binary(), binary(), map()) ->
    {ok, pid()} | {error, term()}.
start_session(SessionId, Principal, Config)
  when is_binary(SessionId), is_binary(Principal), is_map(Config) ->
    HandoffRef = make_ref(),
    ChildId = make_ref(),
    ChildSpec = #{id => ChildId,
                  start => {adk_live_session, start_link, [HandoffRef]},
                  restart => temporary,
                  shutdown => 5000,
                  type => worker,
                  modules => [adk_live_session]},
    case admit_child(ChildSpec) of
        {ok, Pid} ->
            complete_handoff(Pid, ChildId, HandoffRef,
                             SessionId, Principal, Config);
        {ok, Pid, _Info} ->
            complete_handoff(Pid, ChildId, HandoffRef,
                             SessionId, Principal, Config);
        {error, _} = Error -> Error
    end;
start_session(_SessionId, _Principal, _Config) ->
    {error, invalid_live_session_start}.

init([]) ->
    {ok, {#{strategy => one_for_one,
            intensity => 10,
            period => 10}, []}}.

admit_child(ChildSpec) ->
    case configured_session_limit() of
        {ok, Limit} ->
            %% Serialize the count-and-start operation on this node. Counting
            %% does not enumerate children, while the lock prevents concurrent
            %% callers from racing past the hard bound.
            try global:trans(
                  {{?MODULE, node()}, self()},
                  fun() -> admit_child_locked(ChildSpec, Limit) end,
                  [node()]) of
                aborted -> {error, live_session_admission_unavailable};
                Result -> Result
            catch
                _:_ -> {error, live_session_supervisor_unavailable}
            end;
        {error, _} = Error -> Error
    end.

admit_child_locked(ChildSpec, Limit) ->
    Counts = supervisor:count_children(?SERVER),
    Specs = proplists:get_value(specs, Counts, 0),
    case Specs < Limit of
        true -> supervisor:start_child(?SERVER, ChildSpec);
        false -> {error, live_session_limit}
    end.

configured_session_limit() ->
    case application:get_env(erlang_adk, live_session_limit) of
        undefined -> {ok, ?DEFAULT_SESSION_LIMIT};
        {ok, Limit} when is_integer(Limit), Limit >= 1,
                         Limit =< ?MAX_SESSION_LIMIT ->
            {ok, Limit};
        {ok, _Invalid} -> {error, invalid_live_session_limit}
    end.

complete_handoff(Pid, ChildId, HandoffRef,
                 SessionId, Principal, Config) ->
    case adk_live_session:handoff(
           Pid, HandoffRef, SessionId, Principal, Config) of
        ok -> {ok, Pid};
        {error, Reason} ->
            _ = supervisor:terminate_child(?SERVER, ChildId),
            _ = supervisor:delete_child(?SERVER, ChildId),
            {error, Reason}
    end.
