-module(adk_direct_confirmation_test).

-include_lib("eunit/include/eunit.hrl").

-export([on_tool_start/2, before_tool/3, after_tool/4, on_tool_end/2]).

direct_confirmation_test_() ->
    {setup,
     fun() -> application:ensure_all_started(erlang_adk) end,
     fun(_Started) ->
         persistent_term:erase({?MODULE, target}),
         flush_messages()
     end,
     [fun required_confirmation_fails_closed_without_callbacks/0,
      fun required_confirmation_fails_closed_for_fresh_invoke/0,
      fun required_confirmation_fails_closed_through_agent_tool/0,
      fun resolved_module_cannot_weaken_confirmation/0,
      fun conditional_false_executes_directly/0]}.

required_confirmation_fails_closed_without_callbacks() ->
    enable_probes(),
    Name = unique(<<"DirectConfirmedAgent">>),
    Id = <<"destructive-direct-call">>,
    Config = #{provider => adk_llm_probe,
               mode => tool_call,
               call_name => <<"direct_confirmation_probe">>,
               call_args => #{<<"id">> => Id, <<"confirm">> => true},
               call_id => <<"direct-confirm-call">>,
               test_pid => self(),
               callbacks => [?MODULE]},
    {ok, Agent} = erlang_adk:spawn_agent(
                    Name, Config, [adk_direct_confirmation_tool]),
    try
        ?assertEqual({ok, <<"tool complete">>},
                     erlang_adk:prompt(Agent, <<"perform side effect">>)),
        _FirstHistory = receive_history(),
        SecondHistory = receive_history(),
        Result = latest_tool_result(SecondHistory),
        ?assertEqual(false, maps:get(<<"success">>, Result)),
        ?assertEqual(
           <<"tool_confirmation_requires_runner">>,
           maps:get(<<"kind">>, maps:get(<<"error">>, Result))),
        receive
            {direct_confirmation_checked, Id, Context} ->
                ?assertEqual([Name],
                             maps:get('$adk_agent_path', Context))
        after 1000 ->
            error(confirmation_not_evaluated)
        end,
        assert_no_callback_or_execution(),
        ?assert(is_process_alive(Agent))
    after
        _ = catch erlang_adk:stop_agent(Agent)
    end.

required_confirmation_fails_closed_for_fresh_invoke() ->
    enable_probes(),
    Name = unique(<<"FreshConfirmedAgent">>),
    Id = <<"destructive-fresh-call">>,
    Config = #{provider => adk_llm_probe,
               mode => tool_call,
               call_name => <<"direct_confirmation_probe">>,
               call_args => #{<<"id">> => Id, <<"confirm">> => true},
               test_pid => self(),
               callbacks => [?MODULE]},
    {ok, Agent} = erlang_adk:spawn_agent(
                    Name, Config, [adk_direct_confirmation_tool]),
    try
        Context = #{app_name => <<"confirmation-app">>,
                    user_id => <<"confirmation-user">>,
                    session_id => <<"confirmation-session">>},
        ?assertEqual({ok, <<"tool complete">>},
                     erlang_adk:invoke(
                       Agent, <<"perform fresh side effect">>, Context)),
        _FirstHistory = receive_history(),
        Result = latest_tool_result(receive_history()),
        ?assertEqual(
           <<"tool_confirmation_requires_runner">>,
           maps:get(<<"kind">>, maps:get(<<"error">>, Result))),
        receive
            {direct_confirmation_checked, Id, CheckedContext} ->
                ?assertEqual([Name],
                             maps:get('$adk_agent_path', CheckedContext))
        after 1000 ->
            error(fresh_confirmation_not_evaluated)
        end,
        assert_no_callback_or_execution()
    after
        _ = catch erlang_adk:stop_agent(Agent)
    end.

required_confirmation_fails_closed_through_agent_tool() ->
    enable_probes(),
    ChildName = unique(<<"ConfirmedChild">>),
    ParentName = unique(<<"ConfirmedParent">>),
    Id = <<"delegated-destructive-call">>,
    ChildConfig = #{provider => adk_llm_probe,
                    mode => tool_call,
                    call_name => <<"direct_confirmation_probe">>,
                    call_args => #{<<"id">> => Id,
                                   <<"confirm">> => true},
                    test_pid => self(),
                    callbacks => [?MODULE]},
    {ok, Child} = erlang_adk:spawn_agent(
                    ChildName, ChildConfig,
                    [adk_direct_confirmation_tool]),
    ParentConfig = #{provider => adk_llm_probe,
                     mode => sub_agent_call,
                     call_name => ChildName,
                     test_pid => self(),
                     sub_agents => #{ChildName => Child}},
    {ok, Parent} = erlang_adk:spawn_agent(ParentName, ParentConfig, []),
    try
        ?assertEqual({ok, <<"delegation complete">>},
                     erlang_adk:prompt(
                       Parent, <<"delegate the destructive action">>)),
        receive
            {direct_confirmation_checked, Id, CheckedContext} ->
                ?assertEqual([ParentName, ChildName],
                             maps:get('$adk_agent_path', CheckedContext))
        after 1000 ->
            error(delegated_confirmation_not_evaluated)
        end,
        assert_no_callback_or_execution(),
        ?assert(is_process_alive(Parent)),
        ?assert(is_process_alive(Child))
    after
        _ = catch erlang_adk:stop_agent(Parent),
        _ = catch erlang_adk:stop_agent(Child)
    end.

resolved_module_cannot_weaken_confirmation() ->
    enable_probes(),
    Name = unique(<<"ResolvedConfirmedAgent">>),
    Id = <<"resolved-destructive-call">>,
    {ok, Toolset} = adk_toolset:new(
                      adk_resolved_module_toolset,
                      {module, adk_direct_confirmation_tool}),
    Config = #{provider => adk_llm_probe,
               mode => tool_call,
               call_name => <<"direct_confirmation_probe">>,
               call_args => #{<<"id">> => Id, <<"confirm">> => true},
               test_pid => self(),
               callbacks => [?MODULE]},
    {ok, Agent} = erlang_adk:spawn_agent(Name, Config, [Toolset]),
    try
        ?assertEqual({ok, <<"tool complete">>},
                     erlang_adk:prompt(Agent, <<"perform alias side effect">>)),
        _FirstHistory = receive_history(),
        Result = latest_tool_result(receive_history()),
        ?assertEqual(
           <<"tool_confirmation_requires_runner">>,
           maps:get(<<"kind">>, maps:get(<<"error">>, Result))),
        receive
            {direct_confirmation_checked, Id, Context} ->
                ?assertEqual([Name],
                             maps:get('$adk_agent_path', Context))
        after 1000 ->
            error(resolved_module_confirmation_not_evaluated)
        end,
        assert_no_callback_or_execution()
    after
        _ = catch erlang_adk:stop_agent(Agent)
    end.

conditional_false_executes_directly() ->
    enable_probes(),
    Name = unique(<<"DirectConditionalAgent">>),
    Id = <<"read-only-direct-call">>,
    Config = #{provider => adk_llm_probe,
               mode => tool_call,
               call_name => <<"direct_confirmation_probe">>,
               call_args => #{<<"id">> => Id,
                              <<"confirm">> => false},
               test_pid => self()},
    {ok, Agent} = erlang_adk:spawn_agent(
                    Name, Config, [adk_direct_confirmation_tool]),
    try
        ?assertEqual({ok, <<"tool complete">>},
                     erlang_adk:prompt(Agent, <<"read only">>)),
        _FirstHistory = receive_history(),
        SecondHistory = receive_history(),
        ?assertEqual(true,
                     maps:get(<<"success">>,
                              latest_tool_result(SecondHistory))),
        receive
            {direct_confirmation_checked, Id, Context} ->
                ?assertEqual([Name],
                             maps:get('$adk_agent_path', Context))
        after 1000 ->
            error(confirmation_not_evaluated)
        end,
        receive
            {direct_confirmation_executed, Id, _Pid, Context2} ->
                ?assertEqual([Name],
                             maps:get('$adk_agent_path', Context2))
        after 1000 ->
            error(tool_not_executed)
        end
    after
        _ = catch erlang_adk:stop_agent(Agent)
    end.

on_tool_start(Name, _Args) ->
    notify({direct_callback, on_tool_start, Name}),
    ok.

before_tool(Name, _Args, _Context) ->
    notify({direct_callback, before_tool, Name}),
    continue.

after_tool(Name, _Args, _Context, _Result) ->
    notify({direct_callback, after_tool, Name}),
    continue.

on_tool_end(Name, _Result) ->
    notify({direct_callback, on_tool_end, Name}),
    ok.

enable_probes() ->
    flush_messages(),
    persistent_term:put({?MODULE, target}, self()).

notify(Message) ->
    case persistent_term:get({?MODULE, target}, undefined) of
        Pid when is_pid(Pid) -> Pid ! Message;
        _ -> ok
    end.

receive_history() ->
    receive
        {probe_generate, History, _Tools} -> History
    after 1000 ->
        error(provider_not_called)
    end.

latest_tool_result(History) ->
    Results = [tool_result(Content) || #{role := tool,
                                         content := Content} <- History],
    [Result | _] = lists:reverse([Result || {ok, Result} <- Results]),
    Result.

tool_result({tool_response, _Name, Result, _Sig}) -> {ok, Result};
tool_result({tool_response, _Name, Result, _Sig, _CallId}) -> {ok, Result};
tool_result(_Other) -> error.

assert_no_callback_or_execution() ->
    receive
        {direct_callback, _Hook, _Name} ->
            error(callback_ran_before_confirmation);
        {direct_confirmation_executed, _Id, _Pid, _Context} ->
            error(unconfirmed_tool_executed)
    after 50 ->
        ok
    end.

flush_messages() ->
    receive
        {probe_generate, _History, _Tools} -> flush_messages();
        {direct_callback, _Hook, _Name} -> flush_messages();
        {direct_confirmation_checked, _Id, _Context} -> flush_messages();
        {direct_confirmation_executed, _Id, _Pid, _Context} ->
            flush_messages()
    after 0 ->
        ok
    end.

unique(Prefix) ->
    Suffix = integer_to_binary(
               erlang:unique_integer([positive, monotonic])),
    <<Prefix/binary, "_", Suffix/binary>>.
