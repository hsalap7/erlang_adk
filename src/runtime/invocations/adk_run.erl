%% @doc Public, reconnectable invocation API.
%%
%% Runs are owned by a supervised adk_invocation process rather than by the
%% process which starts or subscribes to them. Subscribers receive:
%%
%%   {adk_run_event, RunId, Sequence, Event}
%%   {adk_run_terminal, RunId, Sequence, Outcome}
%%
%% Outcome is one of `{completed, Output}', `{paused, Event}',
%% `{cancelled, Reason}', or `{failed, Reason}'. Every run commits exactly one
%% terminal outcome. A late subscriber receives the bounded event replay and
%% the same terminal outcome while the run remains retained.
%%
%% HTTP and other back-pressure-sensitive consumers should use
%% subscribe_credit/2,3 and acknowledge each delivered sequence with ack/2,3.
%% A credit subscriber has at most one unacknowledged run message in its
%% mailbox.  The original subscribe/1,2 push protocol remains unchanged for
%% local Erlang processes which already drain their mailboxes promptly.
-module(adk_run).

-export([start/4, start/5,
         resume/2, resume/3,
         subscribe/1, subscribe/2,
         subscribe_credit/2, subscribe_credit/3,
         ack/2, ack/3,
         unsubscribe/1, unsubscribe/2,
         status/1,
         await/1, await/2,
         cancel/1, cancel/2]).

-define(DEFAULT_CALL_TIMEOUT, 5000).

-type run_id() :: binary().
-type outcome() ::
    {completed, binary() | adk_content:content()}
    | {paused, term()}
    | {cancelled, term()}
    | {failed, term()}.
-export_type([run_id/0, outcome/0]).

-spec start(adk_runner:runner(), binary(), binary(), term()) ->
    {ok, run_id()} | {error, term()}.
start(Runner, UserId, SessionId, Message) ->
    start(Runner, UserId, SessionId, Message, #{}).

-spec start(adk_runner:runner(), binary(), binary(), term(), map()) ->
    {ok, run_id()} | {error, term()}.
start(Runner, UserId, SessionId, Message, Opts)
  when is_binary(UserId), is_binary(SessionId), is_map(Opts) ->
    RunId = generate_run_id(),
    Request = #{runner => Runner,
                user_id => UserId,
                session_id => SessionId,
                message => Message},
    try adk_invocation_sup:start_invocation(RunId, Request, Opts) of
        {ok, _Pid} -> {ok, RunId};
        {ok, _Pid, _Info} -> {ok, RunId};
        {error, Reason} -> {error, Reason}
    catch
        exit:{noproc, _} -> {error, invocation_supervisor_not_started};
        exit:Reason -> {error, Reason}
    end;
start(_Runner, UserId, SessionId, _Message, Opts) ->
    {error, {invalid_start_arguments, UserId, SessionId, Opts}}.

%% @doc Resume a terminal paused run as a new supervised run.
%%
%% The paused run remains immutable and retained for inspection. The returned
%% run has its own event sequence and terminal outcome, while status/1 links
%% the two runs through `resumed_to' and `parent_run_id'. Only one resume may be
%% accepted for a paused run.
-spec resume(run_id(), term()) -> {ok, run_id()} | {error, term()}.
resume(PausedRunId, ToolResponse) ->
    resume(PausedRunId, ToolResponse, #{}).

-spec resume(run_id(), term(), map()) ->
    {ok, run_id()} | {error, term()}.
resume(PausedRunId, ToolResponse, Opts)
  when is_binary(PausedRunId), is_map(Opts) ->
    NewRunId = generate_run_id(),
    call_run(PausedRunId,
             {resume, NewRunId, ToolResponse, Opts},
             ?DEFAULT_CALL_TIMEOUT);
resume(PausedRunId, _ToolResponse, Opts) ->
    {error, {invalid_resume_arguments, PausedRunId, Opts}}.

-spec subscribe(run_id()) -> ok | {error, term()}.
subscribe(RunId) ->
    subscribe(RunId, self()).

-spec subscribe(run_id(), pid()) -> ok | {error, term()}.
subscribe(RunId, Subscriber) when is_pid(Subscriber) ->
    call_run(RunId, {subscribe, Subscriber}, ?DEFAULT_CALL_TIMEOUT).

%% @doc Subscribe with one-message credit starting strictly after Cursor.
%%
%% The result includes the invocation's latest sequence and terminal state at
%% the subscription boundary. If Cursor is older than the bounded replay
%% window, no subscription is installed and `{error, {replay_gap, Details}}'
%% is returned. Callers must acknowledge each event before another event is
%% released. A terminal message does not need acknowledgement.
-spec subscribe_credit(run_id(), non_neg_integer()) ->
    {ok, map()} | {error, term()}.
subscribe_credit(RunId, Cursor) ->
    subscribe_credit(RunId, self(), Cursor).

-spec subscribe_credit(run_id(), pid(), non_neg_integer()) ->
    {ok, map()} | {error, term()}.
subscribe_credit(RunId, Subscriber, Cursor)
  when is_pid(Subscriber), is_integer(Cursor), Cursor >= 0 ->
    call_run(RunId, {subscribe_credit, Subscriber, Cursor},
             ?DEFAULT_CALL_TIMEOUT);
subscribe_credit(_RunId, Subscriber, Cursor) ->
    {error, {invalid_credit_subscription, Subscriber, Cursor}}.

%% @doc Return credit for the exact event Sequence just consumed.
-spec ack(run_id(), non_neg_integer()) -> ok | {error, term()}.
ack(RunId, Sequence) ->
    ack(RunId, self(), Sequence).

-spec ack(run_id(), pid(), non_neg_integer()) -> ok | {error, term()}.
ack(RunId, Subscriber, Sequence)
  when is_pid(Subscriber), is_integer(Sequence), Sequence >= 0 ->
    call_run(RunId, {ack, Subscriber, Sequence}, ?DEFAULT_CALL_TIMEOUT);
ack(_RunId, Subscriber, Sequence) ->
    {error, {invalid_credit_ack, Subscriber, Sequence}}.

-spec unsubscribe(run_id()) -> ok | {error, term()}.
unsubscribe(RunId) ->
    unsubscribe(RunId, self()).

-spec unsubscribe(run_id(), pid()) -> ok | {error, term()}.
unsubscribe(RunId, Subscriber) when is_pid(Subscriber) ->
    call_run(RunId, {unsubscribe, Subscriber}, ?DEFAULT_CALL_TIMEOUT).

-spec status(run_id()) -> {ok, map()} | {error, term()}.
status(RunId) ->
    case call_run(RunId, status, ?DEFAULT_CALL_TIMEOUT) of
        Status when is_map(Status) -> {ok, Status};
        {error, _} = Error -> Error
    end.

-spec await(run_id()) -> outcome() | {error, term()}.
await(RunId) ->
    await(RunId, infinity).

-spec await(run_id(), timeout()) -> outcome() | {error, term()}.
await(RunId, Timeout)
  when Timeout =:= infinity;
       is_integer(Timeout), Timeout >= 0 ->
    call_run(RunId, await, Timeout).

-spec cancel(run_id()) -> ok | {error, term()}.
cancel(RunId) ->
    cancel(RunId, user_cancelled).

-spec cancel(run_id(), term()) -> ok | {error, term()}.
cancel(RunId, Reason) ->
    call_run(RunId, {cancel, Reason}, ?DEFAULT_CALL_TIMEOUT).

call_run(RunId, Request, Timeout) when is_binary(RunId) ->
    try adk_run_registry:lookup(RunId) of
        {ok, Pid} -> safe_call(Pid, Request, Timeout);
        {error, not_found} = Error -> Error
    catch
        exit:{noproc, _} -> {error, run_registry_not_started};
        exit:Reason -> {error, Reason}
    end;
call_run(RunId, _Request, _Timeout) ->
    {error, {invalid_run_id, RunId}}.

safe_call(Pid, Request, Timeout) ->
    try gen_statem:call(Pid, Request, Timeout) of
        Reply -> Reply
    catch
        exit:{timeout, _} -> {error, timeout};
        exit:{noproc, _} -> {error, not_found};
        exit:{normal, _} -> {error, not_found};
        exit:{shutdown, _} -> {error, not_found};
        exit:Reason -> {error, {run_call_failed, Reason}}
    end.

generate_run_id() ->
    <<A:32, B:16, C:16, D:16, E:48>> = crypto:strong_rand_bytes(16),
    list_to_binary(
      io_lib:format(
        "run-~8.16.0b-~4.16.0b-4~3.16.0b-~4.16.0b-~12.16.0b",
        [A, B, C band 16#0fff,
         D band 16#3fff bor 16#8000, E])).
