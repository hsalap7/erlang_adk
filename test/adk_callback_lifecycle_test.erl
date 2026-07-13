-module(adk_callback_lifecycle_test).
-include_lib("eunit/include/eunit.hrl").

-export([before_model/3, after_model/2, before_tool/3, after_tool/4,
         on_agent_start/2, on_agent_end/2, on_tool_start/2, on_tool_end/2]).

callback_lifecycle_test_() ->
    {setup,
     fun() -> application:ensure_all_started(erlang_adk) end,
     fun(_) -> ok end,
     [
      fun test_before_and_after_model_fired/0
     ]}.

before_model(_Config, _Memory, _Tools) ->
    notify(before_model),
    ok.

after_model(_Config, _Result) ->
    notify(after_model),
    ok.

before_tool(_Name, _Args, _Context) ->
    notify(before_tool),
    ok.

after_tool(_Name, _Args, _Context, _Result) ->
    notify(after_tool),
    ok.

on_agent_start(_Name, _Input) ->
    notify(on_agent_start),
    ok.

on_agent_end(_Name, _Output) ->
    notify(on_agent_end),
    ok.

on_tool_start(_Name, _Args) ->
    notify(on_tool_start),
    ok.

on_tool_end(_Name, _Result) ->
    notify(on_tool_end),
    ok.

test_before_and_after_model_fired() ->
    persistent_term:put({?MODULE, target}, self()),
    
    %% Create agent with callbacks pointing to this module
    LLMConfig = #{
        provider => adk_llm_dummy,
        callbacks => [?MODULE]
    },
    {ok, Pid} = erlang_adk:spawn_agent("CallbackAgent", LLMConfig,
                                       [dummy_tool]),
    {ok, <<"Tool executed">>} = erlang_adk:prompt(Pid, "Trigger tool"),
    Events = receive_events(10, []),
    ?assertEqual(1, count(on_agent_start, Events)),
    ?assertEqual(1, count(on_agent_end, Events)),
    ?assertEqual(2, count(before_model, Events)),
    ?assertEqual(2, count(after_model, Events)),
    ?assertEqual(1, count(on_tool_start, Events)),
    ?assertEqual(1, count(before_tool, Events)),
    ?assertEqual(1, count(after_tool, Events)),
    ?assertEqual(1, count(on_tool_end, Events)),
    ok = erlang_adk:stop_agent(Pid),
    persistent_term:erase({?MODULE, target}).

notify(Event) ->
    case persistent_term:get({?MODULE, target}, undefined) of
        Pid when is_pid(Pid) -> Pid ! {callback, Event};
        _ -> ok
    end.

receive_events(0, Acc) ->
    Acc;
receive_events(Remaining, Acc) ->
    receive
        {callback, Event} -> receive_events(Remaining - 1, [Event | Acc])
    after 1000 ->
        Acc
    end.

count(Event, Events) ->
    length([ok || Seen <- Events, Seen =:= Event]).
