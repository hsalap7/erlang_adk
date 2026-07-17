-module(adk_ambient_concurrency_SUITE).

-include_lib("common_test/include/ct.hrl").
-include("adk_event.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([bounded_hundred_event_burst/1]).

-define(APP, <<"adk_ambient_ct">>).

all() ->
    [bounded_hundred_event_burst].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(erlang_adk),
    ok = erlang_adk_session:init(),
    Config.

end_per_suite(_Config) ->
    ok.

bounded_hundred_event_burst(_Config) ->
    Trigger = unique(<<"ambient-ct">>),
    User = unique(<<"ambient-ct-user">>),
    Agent = spawn(fun() -> agent_loop(0, 0) end),
    Runner = adk_runner:new(Agent, ?APP, erlang_adk_session,
                            #{run_timeout => 5000}),
    Options = #{max_concurrency => 8,
                max_queue => 100,
                event_timeout => 10000,
                retention_ms => 10000,
                max_retained => 150,
                max_waiters => 16,
                session_policy => #{mode => per_event,
                                    user_id => User,
                                    prefix => <<"burst-">>},
                retry => #{max_attempts => 1,
                           initial_delay => 0,
                           max_delay => 0,
                           backoff_factor => 1.0,
                           attempt_timeout => 5000,
                           max_heap_words => 100000,
                           jitter => none}},
    ok = adk_ambient:register_trigger(Trigger, Runner, Options),
    try
        Refs = [begin
                    Key = <<"event-", (integer_to_binary(Index))/binary>>,
                    {ok, Ref} = adk_ambient:submit(
                                  Trigger,
                                  #{payload => Key,
                                    idempotency_key => Key}),
                    Ref
                end || Index <- lists:seq(1, 100)],
        lists:foreach(
          fun(Ref) ->
              {completed, _} = adk_ambient:await(Ref, 10000)
          end, Refs),
        Agent ! {get_max, self()},
        receive
            {agent_max, Agent, Max} when Max =:= 8 -> ok;
            {agent_max, Agent, Other} ->
                ct:fail({unexpected_max_concurrency, Other})
        after 1000 ->
            ct:fail(agent_status_timeout)
        end,
        {ok, Status} = adk_ambient:trigger_status(Trigger),
        0 = maps:get(active, Status),
        0 = maps:get(queued, Status),
        {ok, Admission} = adk_admission_control:status(),
        0 = maps:get(active, Admission)
    after
        _ = adk_ambient:unregister_trigger(Trigger),
        Agent ! stop
    end.

agent_loop(Active, Max) ->
    receive
        {'$gen_call', From, get_runtime} ->
            gen_server:reply(From, {ok, <<"ambient-ct-agent">>,
                                    #{}, [], #{}}),
            agent_loop(Active, Max);
        {'$gen_call', From,
         {run_with_events, _History, InvocationId}} ->
            Active1 = Active + 1,
            erlang:send_after(20, self(),
                              {reply, From, InvocationId}),
            agent_loop(Active1, erlang:max(Max, Active1));
        {reply, From, InvocationId} ->
            Final = adk_event:new(
                      <<"ambient-ct-agent">>, <<"done">>,
                      #{invocation_id => InvocationId, is_final => true}),
            gen_server:reply(From, {ok, Final}),
            agent_loop(Active - 1, Max);
        {get_max, Caller} ->
            Caller ! {agent_max, self(), Max},
            agent_loop(Active, Max);
        stop ->
            ok;
        _Other ->
            agent_loop(Active, Max)
    end.

unique(Prefix) ->
    Suffix = integer_to_binary(
               erlang:unique_integer([positive, monotonic])),
    <<Prefix/binary, "-", Suffix/binary>>.
