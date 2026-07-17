-module(adk_concurrency_stress_SUITE).

-include_lib("common_test/include/ct.hrl").
-include("adk_event.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1,
         thousand_correlated_invocations/1]).

-define(APP, <<"adk_stress">>).
-define(USER, <<"stress-user">>).
-define(AGENT_COUNT, 32).
-define(INVOCATION_COUNT, 1000).
-define(BATCH_SIZE, 50).

all() -> [thousand_correlated_invocations].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(erlang_adk),
    ok = erlang_adk_session:init(),
    Prefix = integer_to_binary(erlang:unique_integer([positive, monotonic])),
    Agents = [begin
                  Name = <<"StressAgent_", Prefix/binary, "_",
                           (integer_to_binary(Index))/binary>>,
                  {ok, Pid} = erlang_adk:spawn_agent(
                                Name,
                                #{provider => adk_llm_correlation_probe},
                                []),
                  Pid
              end || Index <- lists:seq(1, ?AGENT_COUNT)],
    [{agents, Agents} | Config].

end_per_suite(Config) ->
    lists:foreach(
      fun(Pid) -> _ = catch erlang_adk:stop_agent(Pid) end,
      ?config(agents, Config)),
    ok.

thousand_correlated_invocations(Config) ->
    Agents = ?config(agents, Config),
    InvocationBaseline = active_children(adk_invocation_sup),
    TaskBaseline = active_children(adk_task_sup),
    {message_queue_len, MailboxBaseline} =
        process_info(self(), message_queue_len),
    Ids = lists:seq(1, ?INVOCATION_COUNT),
    RunIds = run_batches(Ids, Agents, []),
    ?INVOCATION_COUNT = length(RunIds),
    ?INVOCATION_COUNT = length(lists:usort(RunIds)),
    ok = await_active_children(
           adk_invocation_sup, InvocationBaseline, 3000),
    ok = await_active_children(adk_task_sup, TaskBaseline, 3000),
    {message_queue_len, MailboxAfter} =
        process_info(self(), message_queue_len),
    true = MailboxAfter =< MailboxBaseline,
    ok.

run_batches([], _Agents, Acc) ->
    lists:reverse(Acc);
run_batches(Ids, Agents, Acc) ->
    {Batch, Rest} = lists:split(min(?BATCH_SIZE, length(Ids)), Ids),
    Started = [start_invocation(Id, Agents) || Id <- Batch],
    lists:foreach(fun await_and_verify/1, Started),
    run_batches(Rest, Agents,
                lists:reverse([RunId || {_Id, RunId, _Session, _Message}
                                          <- Started]) ++ Acc).

start_invocation(Id, Agents) ->
    Agent = lists:nth(((Id - 1) rem length(Agents)) + 1, Agents),
    Session = <<"stress-session-", (integer_to_binary(Id))/binary>>,
    Message = <<"correlation-", (integer_to_binary(Id))/binary>>,
    Runner = adk_runner:new(
               Agent, ?APP, erlang_adk_session,
               #{run_timeout => 5000,
                 max_llm_calls => 2,
                 max_tool_rounds => 1}),
    {ok, RunId} = adk_run:start(
                    Runner, ?USER, Session, Message,
                    #{retention_ms => 2000,
                      max_buffered_events => 4}),
    {Id, RunId, Session, Message}.

await_and_verify({_Id, RunId, Session, Message}) ->
    {completed, Message} = adk_run:await(RunId, 5000),
    {ok, #{events := Events}} = erlang_adk_session:get_session(
                                 ?APP, ?USER, Session),
    [Message, Message] =
        [event_text(Event) || Event <- Events,
                              Event#adk_event.author =:= <<"user">> orelse
                              Event#adk_event.is_final =:= true],
    [_InvocationId] = lists:usort(
                        [Event#adk_event.invocation_id || Event <- Events]),
    ok = erlang_adk_session:delete_session(?APP, ?USER, Session).

event_text(#adk_event{content = Content}) when is_binary(Content) -> Content;
event_text(#adk_event{content = #{<<"type">> := <<"text">>,
                                  <<"text">> := Text}}) -> Text;
event_text(#adk_event{content = #{type := text, text := Text}}) -> Text.

active_children(Supervisor) ->
    proplists:get_value(active, supervisor:count_children(Supervisor), 0).

await_active_children(Supervisor, Expected, Timeout) ->
    Deadline = erlang:monotonic_time(millisecond) + Timeout,
    await_active_children_until(Supervisor, Expected, Deadline).

await_active_children_until(Supervisor, Expected, Deadline) ->
    case active_children(Supervisor) of
        Expected -> ok;
        Actual ->
            case erlang:monotonic_time(millisecond) >= Deadline of
                true -> {error, {orphan_children, Supervisor,
                                 Expected, Actual}};
                false ->
                    receive after 10 -> ok end,
                    await_active_children_until(
                      Supervisor, Expected, Deadline)
            end
    end.
