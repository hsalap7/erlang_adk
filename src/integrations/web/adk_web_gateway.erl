%% @doc Production UI boundary for authenticated Phoenix/HTTP applications.
%%
%% The gateway is deliberately not an HTTP server. A Phoenix LiveView (or
%% another trusted boundary) authenticates a request, passes the resulting
%% `adk_jwt_policy' identity here, and never accepts app/user identifiers from
%% the browser. Agent runners are resolved from a server-owned immutable
%% catalog. Long-running work remains in independently supervised `adk_run'
%% processes; the gateway performs only short authorization/catalog lookups.
-module(adk_web_gateway).

-behaviour(gen_server).

-export([start_link/1, child_spec/1,
         list_agents/2, start_run/5, status/3,
         subscribe_credit/5, ack/5, unsubscribe/4,
         cancel/3, resume/4]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3, format_status/1]).

-define(DEFAULT_TIMEOUT_MS, 5000).
-define(DEFAULT_MAX_MESSAGE_BYTES, 1048576).
-define(DEFAULT_MAX_DECISION_BYTES, 65536).
-define(DEFAULT_AUTHORIZER_TIMEOUT_MS, 1000).
-define(MAX_AUTHORIZER_TIMEOUT_MS, 4000).
-define(DEFAULT_AUTHORIZER_MAX_HEAP_WORDS, 100000).
-define(MAX_AUTHORIZER_MAX_HEAP_WORDS, 1000000).
-define(DEFAULT_MAX_AUTHORIZATIONS, 64).
-define(MAX_AUTHORIZATIONS, 1024).
-define(MAX_AUTHORIZATION_INPUT_BYTES, 262144).
-define(MAX_AUTHORIZATION_POLICY_BYTES, 1048576).
-define(MAX_AGENTS, 256).

-record(state, {
    agents :: map(),
    authorizer :: module(),
    policy :: term(),
    authorizer_timeout_ms :: pos_integer(),
    authorizer_max_heap_words :: pos_integer(),
    max_authorizations :: pos_integer(),
    authorizations = #{} :: map(),
    authorization_monitors = #{} :: map(),
    max_message_bytes :: pos_integer(),
    max_decision_bytes :: pos_integer()
}).

-spec start_link(map()) -> gen_server:start_ret().
start_link(Opts) when is_map(Opts) ->
    case maps:get(name, Opts, undefined) of
        undefined -> gen_server:start_link(?MODULE, Opts, []);
        Name when is_atom(Name), Name =/= undefined ->
            gen_server:start_link({local, Name}, ?MODULE, Opts, []);
        _ -> {error, invalid_web_gateway_name}
    end.

-spec child_spec(map()) -> supervisor:child_spec().
child_spec(Opts) ->
    #{id => maps:get(id, Opts, ?MODULE),
      start => {?MODULE, start_link, [Opts]},
      restart => permanent,
      shutdown => 5000,
      type => worker,
      modules => [?MODULE]}.

-spec list_agents(gen_server:server_ref(), map()) ->
    {ok, [map()]} | {error, term()}.
list_agents(Server, Identity) ->
    safe_call(Server, {authorize, Identity, list_agents, #{}},
              fun({ok, _Decision, Public}) -> {ok, Public};
                 (Error) -> Error
              end).

-spec start_run(gen_server:server_ref(), map(), binary(), binary(), binary()) ->
    {ok, adk_run:run_id()} | {error, term()}.
start_run(Server, Identity, AgentId, SessionId, Message)
  when is_binary(AgentId), is_binary(SessionId), is_binary(Message) ->
    safe_call(
      Server, {authorize_start, Identity, AgentId, SessionId, Message},
      fun({ok, Decision, Entry}) ->
              Runner = maps:get(runner, Entry),
              UserId = maps:get(user_id, Decision),
              TrustedOpts = maps:get(run_options, Entry, #{}),
              RunOpts = TrustedOpts#{owner_scope =>
                                         maps:get(owner_scope, Decision)},
              adk_run:start(Runner, UserId, SessionId, Message, RunOpts);
         (Error) -> Error
      end);
start_run(_Server, _Identity, _AgentId, _SessionId, _Message) ->
    {error, invalid_run_request}.

-spec status(gen_server:server_ref(), map(), binary()) ->
    {ok, map()} | {error, term()}.
status(Server, Identity, RunId) ->
    with_owned_run(Server, Identity, observe_run, RunId,
                   fun() -> adk_run:status(RunId) end).

-spec subscribe_credit(gen_server:server_ref(), map(), binary(), pid(),
                       non_neg_integer()) ->
    {ok, map()} | {error, term()}.
subscribe_credit(Server, Identity, RunId, Subscriber, Cursor)
  when is_pid(Subscriber), is_integer(Cursor), Cursor >= 0 ->
    with_owned_run(
      Server, Identity, observe_run, RunId,
      fun() -> adk_run:subscribe_credit(RunId, Subscriber, Cursor) end);
subscribe_credit(_Server, _Identity, _RunId, _Subscriber, _Cursor) ->
    {error, invalid_subscription}.

-spec ack(gen_server:server_ref(), map(), binary(), pid(),
          non_neg_integer()) -> ok | {error, term()}.
ack(Server, Identity, RunId, Subscriber, Sequence)
  when is_pid(Subscriber), is_integer(Sequence), Sequence >= 0 ->
    with_owned_run(
      Server, Identity, observe_run, RunId,
      fun() -> adk_run:ack(RunId, Subscriber, Sequence) end);
ack(_Server, _Identity, _RunId, _Subscriber, _Sequence) ->
    {error, invalid_ack}.

-spec unsubscribe(gen_server:server_ref(), map(), binary(), pid()) ->
    ok | {error, term()}.
unsubscribe(Server, Identity, RunId, Subscriber) when is_pid(Subscriber) ->
    with_owned_run(
      Server, Identity, observe_run, RunId,
      fun() -> adk_run:unsubscribe(RunId, Subscriber) end);
unsubscribe(_Server, _Identity, _RunId, _Subscriber) ->
    {error, invalid_unsubscribe}.

-spec cancel(gen_server:server_ref(), map(), binary()) ->
    ok | {error, term()}.
cancel(Server, Identity, RunId) ->
    with_owned_run(
      Server, Identity, control_run, RunId,
      fun() -> adk_run:cancel(RunId, web_user_cancelled) end).

-spec resume(gen_server:server_ref(), map(), binary(), term()) ->
    {ok, adk_run:run_id()} | {error, term()}.
resume(Server, Identity, RunId, Decision) ->
    case normalize_decision(Server, Decision) of
        {ok, SafeDecision} ->
            with_owned_run(
              Server, Identity, resume_run, RunId,
              fun() -> adk_run:resume(RunId, SafeDecision) end);
        {error, _} = Error -> Error
    end.

init(Opts) ->
    Agents0 = maps:get(agents, Opts, undefined),
    Authorizer = maps:get(authorizer, Opts, adk_scope_authorizer),
    PolicyConfig = maps:get(policy, Opts, undefined),
    MaxMessage = maps:get(max_message_bytes, Opts,
                          ?DEFAULT_MAX_MESSAGE_BYTES),
    MaxDecision = maps:get(max_decision_bytes, Opts,
                           ?DEFAULT_MAX_DECISION_BYTES),
    AuthorizerTimeout = maps:get(authorizer_timeout_ms, Opts,
                                 ?DEFAULT_AUTHORIZER_TIMEOUT_MS),
    AuthorizerHeap = maps:get(authorizer_max_heap_words, Opts,
                              ?DEFAULT_AUTHORIZER_MAX_HEAP_WORDS),
    MaxAuthorizations = maps:get(max_authorizations, Opts,
                                 ?DEFAULT_MAX_AUTHORIZATIONS),
    LimitsValid = valid_limit(AuthorizerTimeout,
                              ?MAX_AUTHORIZER_TIMEOUT_MS) andalso
                  valid_limit(AuthorizerHeap,
                              ?MAX_AUTHORIZER_MAX_HEAP_WORDS) andalso
                  valid_limit(MaxAuthorizations, ?MAX_AUTHORIZATIONS),
    Policy = case LimitsValid of
        true -> normalize_policy(Authorizer, PolicyConfig,
                                 AuthorizerTimeout, AuthorizerHeap);
        false -> error
    end,
    case {normalize_agents(Agents0), Policy,
          valid_limit(MaxMessage, 16777216),
          valid_limit(MaxDecision, 1048576), LimitsValid} of
        {{ok, Agents}, {ok, NormalizedPolicy}, true, true, true} ->
            {ok, #state{agents = Agents, authorizer = Authorizer,
                        policy = NormalizedPolicy,
                        authorizer_timeout_ms = AuthorizerTimeout,
                        authorizer_max_heap_words = AuthorizerHeap,
                        max_authorizations = MaxAuthorizations,
                        max_message_bytes = MaxMessage,
                        max_decision_bytes = MaxDecision}};
        _ ->
            {stop, invalid_web_gateway_options}
    end.

handle_call({authorize, Identity, list_agents, Resource}, _From, State) ->
    start_authorization(Identity, list_agents, Resource, list_agents,
                        _From, State);
handle_call({authorize_start, Identity, AgentId, SessionId, Message},
            From, State) ->
    case valid_session_id(SessionId) andalso
         byte_size(Message) =< State#state.max_message_bytes andalso
         valid_utf8(Message) of
        false -> {reply, {error, invalid_run_request}, State};
        true ->
            %% Resolve the private catalog entry only after authorization.
            %% Otherwise an unauthenticated or unauthorized caller could
            %% distinguish a known agent id from an unknown one by comparing
            %% forbidden/not_found responses.
            start_authorization(Identity, start_run,
                                #{agent => AgentId},
                                {start_run, AgentId}, From, State)
    end;
handle_call({authorize_run, Identity, Action, RunId}, From, State) ->
    start_authorization(Identity, Action, #{run => RunId}, direct,
                        From, State);
handle_call(max_decision_bytes, _From, State) ->
    {reply, State#state.max_decision_bytes, State};
handle_call(_Request, _From, State) ->
    {reply, {error, invalid_gateway_request}, State}.

handle_cast(_Message, State) -> {noreply, State}.
handle_info({web_authorization_result, JobRef, Worker, CompletedAt, Result},
            State) ->
    case maps:find(JobRef, State#state.authorizations) of
        {ok, #{worker := Worker, from := From,
               continuation := Continuation, deadline := Deadline}} ->
            Reply = case CompletedAt =< Deadline of
                true -> authorization_reply(Continuation, Result, State);
                false -> {error, forbidden}
            end,
            gen_server:reply(From, Reply),
            {noreply, remove_authorization(JobRef, false, State)};
        _ ->
            {noreply, State}
    end;
handle_info({web_authorization_timeout, JobRef}, State) ->
    case maps:find(JobRef, State#state.authorizations) of
        {ok, #{worker := Worker, from := From}} ->
            exit(Worker, kill),
            gen_server:reply(From, {error, forbidden}),
            {noreply, remove_authorization(JobRef, false, State)};
        error ->
            {noreply, State}
    end;
handle_info({'DOWN', Monitor, process, _Pid, _Reason}, State) ->
    case maps:find(Monitor, State#state.authorization_monitors) of
        {ok, {worker, JobRef}} ->
            case maps:find(JobRef, State#state.authorizations) of
                {ok, #{from := From}} ->
                    gen_server:reply(From, {error, forbidden}),
                    {noreply, remove_authorization(JobRef, false, State)};
                error -> {noreply, State}
            end;
        {ok, {caller, JobRef}} ->
            {noreply, remove_authorization(JobRef, true, State)};
        error ->
            {noreply, State}
    end;
handle_info(_Message, State) -> {noreply, State}.
terminate(_Reason, #state{authorizations = Authorizations}) ->
    maps:foreach(
      fun(_JobRef, #{worker := Worker}) -> exit(Worker, kill) end,
      Authorizations),
    ok.
code_change(_OldVsn, State, _Extra) -> {ok, State}.

format_status(Status) ->
    maps:map(
      fun(state, #state{agents = Agents, authorizer = Authorizer,
                        authorizer_timeout_ms = AuthorizerTimeout,
                        authorizer_max_heap_words = AuthorizerHeap,
                        max_authorizations = MaxAuthorizations,
                        authorizations = Authorizations,
                        max_message_bytes = MaxMessage,
                        max_decision_bytes = MaxDecision}) ->
              #{agent_count => map_size(Agents), authorizer => Authorizer,
                authorizer_timeout_ms => AuthorizerTimeout,
                authorizer_max_heap_words => AuthorizerHeap,
                max_authorizations => MaxAuthorizations,
                active_authorizations => map_size(Authorizations),
                max_message_bytes => MaxMessage,
                max_decision_bytes => MaxDecision};
         (message, _Message) -> adk_secret_redactor:marker();
         (log, _Log) -> [];
         (reason, _Reason) -> adk_secret_redactor:marker();
         (_Key, _Value) -> adk_secret_redactor:marker()
      end, Status).

with_owned_run(Server, Identity, Action, RunId, Operation)
  when is_binary(RunId), is_function(Operation, 0) ->
    safe_call(
      Server, {authorize_run, Identity, Action, RunId},
      fun({ok, Decision}) ->
              OwnerScope = maps:get(owner_scope, Decision),
              case safe_owned_lookup(RunId, OwnerScope) of
                  {ok, _Pid} -> Operation();
                  {error, not_found} = Error -> Error
              end;
         (Error) -> Error
      end);
with_owned_run(_Server, _Identity, _Action, _RunId, _Operation) ->
    {error, not_found}.

safe_owned_lookup(RunId, OwnerScope) ->
    try adk_run_registry:lookup_authorized(RunId, OwnerScope) of
        Reply -> Reply
    catch
        exit:_ -> {error, not_found}
    end.

normalize_decision(Server, Decision) ->
    case adk_json:normalize(Decision) of
        {ok, SafeDecision} ->
            try jsx:encode(SafeDecision) of
                Encoded ->
                    Max = gen_server:call(Server, max_decision_bytes,
                                          ?DEFAULT_TIMEOUT_MS),
                    case byte_size(Encoded) =< Max of
                        true -> {ok, SafeDecision};
                        false -> {error, decision_too_large}
                    end
            catch _:_ -> {error, invalid_decision}
            end;
        {error, _} -> {error, invalid_decision}
    end.

safe_call(Server, Request, Continue) ->
    try gen_server:call(Server, Request, ?DEFAULT_TIMEOUT_MS) of
        Reply -> Continue(Reply)
    catch
        exit:{timeout, _} -> {error, gateway_timeout};
        exit:_ -> {error, gateway_unavailable}
    end.

start_authorization(Identity, Action, Resource, Continuation, From,
                    State = #state{authorizations = Authorizations,
                                   max_authorizations = Maximum}) ->
    Input = {Identity, Action, Resource},
    case bounded_term(Input, ?MAX_AUTHORIZATION_INPUT_BYTES) of
        false -> {reply, {error, forbidden}, State};
        true when map_size(Authorizations) >= Maximum ->
            {reply, {error, gateway_busy}, State};
        true ->
            JobRef = make_ref(),
            Gateway = self(),
            Deadline = erlang:monotonic_time(millisecond)
                       + State#state.authorizer_timeout_ms,
            Module = State#state.authorizer,
            Policy = State#state.policy,
            Work = fun() ->
                start_owner_watchdog(Gateway, self()),
                Result = safe_authorize(Module, Policy, Identity, Action,
                                        Resource),
                CompletedAt = erlang:monotonic_time(millisecond),
                Gateway ! {web_authorization_result, JobRef, self(),
                           CompletedAt, Result}
            end,
            {Worker, WorkerMonitor} = spawn_opt(
                Work,
                [monitor, {message_queue_data, off_heap},
                 {max_heap_size,
                  #{size => State#state.authorizer_max_heap_words,
                    kill => true, error_logger => false,
                    include_shared_binaries => true}}]),
            {Caller, _Tag} = From,
            CallerMonitor = erlang:monitor(process, Caller),
            Timer = erlang:send_after(
                      erlang:max(0, Deadline -
                                    erlang:monotonic_time(millisecond)), self(),
                      {web_authorization_timeout, JobRef}),
            Entry = #{from => From, worker => Worker,
                      worker_monitor => WorkerMonitor,
                      caller_monitor => CallerMonitor, timer => Timer,
                      continuation => Continuation, deadline => Deadline},
            Monitors = State#state.authorization_monitors,
            {noreply,
             State#state{
               authorizations = Authorizations#{JobRef => Entry},
               authorization_monitors =
                   Monitors#{WorkerMonitor => {worker, JobRef},
                             CallerMonitor => {caller, JobRef}}}}
    end.

safe_authorize(Module, Policy, Identity, Action, Resource) ->
    try Module:authorize(Policy, Identity, Action, Resource) of
        {ok, #{owner_scope := Scope, user_id := UserId}}
          when is_binary(Scope), byte_size(Scope) =:= 32,
               is_binary(UserId), byte_size(UserId) > 0,
               byte_size(UserId) =< 256 ->
            {ok, #{owner_scope => Scope, user_id => UserId}};
        {error, unauthenticated} = Error -> Error;
        {error, forbidden} = Error -> Error;
        _ -> {error, forbidden}
    catch _:_ -> {error, forbidden}
    end.

authorization_reply(list_agents, {ok, Decision}, State) ->
    Public = [maps:get(public, Entry)
              || {_Id, Entry} <- lists:sort(
                                    maps:to_list(State#state.agents))],
    {ok, Decision, Public};
authorization_reply({start_run, AgentId}, {ok, Decision}, State) ->
    case maps:find(AgentId, State#state.agents) of
        {ok, Entry} -> {ok, Decision, Entry};
        error -> {error, not_found}
    end;
authorization_reply(direct, Result, _State) -> Result;
authorization_reply(_Continuation, Error, _State) -> Error.

remove_authorization(JobRef, KillWorker,
                     State = #state{authorizations = Authorizations0,
                                    authorization_monitors = Monitors0}) ->
    case maps:take(JobRef, Authorizations0) of
        {Entry, Authorizations} ->
            Worker = maps:get(worker, Entry),
            case KillWorker andalso is_process_alive(Worker) of
                true -> exit(Worker, kill);
                false -> ok
            end,
            _ = erlang:cancel_timer(maps:get(timer, Entry)),
            WorkerMonitor = maps:get(worker_monitor, Entry),
            CallerMonitor = maps:get(caller_monitor, Entry),
            _ = erlang:demonitor(WorkerMonitor, [flush]),
            _ = erlang:demonitor(CallerMonitor, [flush]),
            State#state{
              authorizations = Authorizations,
              authorization_monitors =
                  maps:remove(CallerMonitor,
                              maps:remove(WorkerMonitor, Monitors0))};
        error -> State
    end.

normalize_policy(Module, Config, Timeout, MaxHeap)
  when is_atom(Module), Module =/= undefined ->
    Callback = fun() -> Module:new(Config) end,
    Normalizer = fun({ok, Policy}) -> {ok, Policy};
                    (_) -> error
                 end,
    case adk_auth_callback_guard:run(
           Callback, Normalizer, Timeout, MaxHeap,
           ?MAX_AUTHORIZATION_POLICY_BYTES) of
        {ok, {ok, Policy}} -> {ok, Policy};
        _ -> error
    end;
normalize_policy(_, _, _, _) -> error.

normalize_agents(Agents) when is_map(Agents), map_size(Agents) > 0,
                              map_size(Agents) =< ?MAX_AGENTS ->
    normalize_agent_pairs(maps:to_list(Agents), #{});
normalize_agents(_) -> error.

normalize_agent_pairs([], Acc) -> {ok, Acc};
normalize_agent_pairs([{Id, Value} | Rest], Acc)
  when is_binary(Id), byte_size(Id) > 0, byte_size(Id) =< 128 ->
    case normalize_agent(Id, Value) of
        {ok, Entry} -> normalize_agent_pairs(Rest, Acc#{Id => Entry});
        error -> error
    end;
normalize_agent_pairs(_, _) -> error.

normalize_agent(Id, #{runner := Runner} = Config) ->
    Allowed = [runner, label, description, run_options],
    Label = maps:get(label, Config, Id),
    Description = maps:get(description, Config, <<>>),
    RunOptions = maps:get(run_options, Config, #{}),
    case maps:keys(Config) -- Allowed =:= [] andalso
         adk_runner:is_runner(Runner) andalso valid_text(Label, 256) andalso
         valid_text(Description, 4096) andalso is_map(RunOptions) andalso
         not maps:is_key(owner_scope, RunOptions) of
        true ->
            Public = #{id => Id, label => Label, description => Description},
            {ok, #{runner => Runner, run_options => RunOptions,
                   public => Public}};
        false -> error
    end;
normalize_agent(Id, Runner) ->
    case adk_runner:is_runner(Runner) of
        true -> normalize_agent(Id, #{runner => Runner});
        false -> error
    end.

valid_session_id(Value) ->
    is_binary(Value) andalso byte_size(Value) > 0 andalso
    byte_size(Value) =< 256 andalso valid_utf8(Value) andalso
    lists:all(fun(C) -> C >= 16#21 andalso C =< 16#7e end,
              binary_to_list(Value)).

valid_text(Value, Max) ->
    is_binary(Value) andalso byte_size(Value) =< Max andalso valid_utf8(Value).

valid_utf8(Value) ->
    try unicode:characters_to_binary(Value, utf8, utf8) of
        Value -> true;
        _ -> false
    catch _:_ -> false
    end.

valid_limit(Value, Max) ->
    is_integer(Value) andalso Value > 0 andalso Value =< Max.

bounded_term(Term, Maximum) ->
    try erlang:external_size(Term) =< Maximum
    catch _:_ -> false
    end.

start_owner_watchdog(Owner, Worker) ->
    _ = spawn_opt(
          fun() -> owner_watchdog(Owner, Worker) end,
          [{message_queue_data, off_heap},
           {max_heap_size,
            #{size => 8192, kill => true, error_logger => false,
              include_shared_binaries => true}}]),
    ok.

owner_watchdog(Owner, Worker) ->
    OwnerMonitor = erlang:monitor(process, Owner),
    WorkerMonitor = erlang:monitor(process, Worker),
    receive
        {'DOWN', OwnerMonitor, process, Owner, _OpaqueReason} ->
            exit(Worker, kill),
            _ = erlang:demonitor(WorkerMonitor, [flush]),
            ok;
        {'DOWN', WorkerMonitor, process, Worker, _OpaqueReason} ->
            _ = erlang:demonitor(OwnerMonitor, [flush]),
            ok
    end.
