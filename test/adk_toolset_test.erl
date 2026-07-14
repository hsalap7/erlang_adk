-module(adk_toolset_test).

-include_lib("eunit/include/eunit.hrl").

-define(APP, <<"toolset_app">>).
-define(USER, <<"toolset_user">>).

toolset_test_() ->
    {setup,
     fun setup/0,
     fun(_State) -> ok end,
     [fun descriptor_schema_and_resolution/0,
      fun direct_agent_executes_resolved_call/0,
      fun runner_executes_resolved_call_in_parallel_mode/0,
      fun invalid_toolset_fails_agent_start/0]}.

setup() ->
    {ok, _} = application:ensure_all_started(erlang_adk),
    ok = erlang_adk_session:init().

descriptor_schema_and_resolution() ->
    {ok, Descriptor} = adk_toolset:new(adk_test_toolset, self()),
    {ok, [Schema]} = adk_toolset:expand_tools([Descriptor]),
    ?assertEqual(<<"dynamic_echo">>, maps:get(<<"name">>, Schema)),
    Args = #{<<"text">> => <<"hello">>},
    Context = #{invocation_id => <<"inv-1">>},
    {ok, {resolved, Call}} = adk_toolset:resolve(
                               [Descriptor], <<"dynamic_echo">>,
                               Args, Context),
    ?assertEqual(true, adk_tool_executor:is_parallel_safe(Call)),
    ?assertEqual({error, not_found},
                 adk_toolset:resolve(
                   [Descriptor], <<"missing">>, #{}, Context)).

direct_agent_executes_resolved_call() ->
    {ok, Descriptor} = adk_toolset:new(adk_test_toolset, self()),
    Name = unique_name("DirectToolset"),
    {ok, Agent} = erlang_adk:spawn_agent(
                    Name,
                    #{provider => adk_llm_probe,
                      mode => tool_call,
                      call_name => <<"dynamic_echo">>,
                      call_args => #{<<"text">> => <<"direct">>},
                      response => <<"direct complete">>,
                      test_pid => self()},
                    [Descriptor]),
    try
        ?assertEqual({ok, <<"direct complete">>},
                     erlang_adk:prompt(Agent, <<"echo">>)),
        assert_model_saw_schema(),
        Context = receive_execution(<<"direct">>),
        ?assertEqual(undefined, maps:get(invocation_id, Context)),
        ?assertEqual(undefined, maps:get(session_id, Context))
    after
        ok = erlang_adk:stop_agent(Agent)
    end.

runner_executes_resolved_call_in_parallel_mode() ->
    {ok, Descriptor} = adk_toolset:new(adk_test_toolset, self()),
    Name = unique_name("RunnerToolset"),
    {ok, Agent} = erlang_adk:spawn_agent(
                    Name,
                    #{provider => adk_llm_probe,
                      mode => tool_call,
                      call_name => <<"dynamic_echo">>,
                      call_args => #{<<"text">> => <<"runner">>},
                      response => <<"runner complete">>},
                    [Descriptor]),
    SessionId = unique_binary("toolset-session"),
    Runner = adk_runner:new(
               Agent, ?APP, erlang_adk_session,
               #{run_timeout => 3000,
                 tool_execution =>
                     #{mode => parallel, max_concurrency => 2,
                       tool_timeout => 1000}}),
    try
        ?assertEqual({ok, <<"runner complete">>},
                     adk_runner:run(
                       Runner, ?USER, SessionId, <<"echo">>)),
        Context = receive_execution(<<"runner">>),
        ?assertEqual(SessionId, maps:get(session_id, Context)),
        ?assertEqual(?USER, maps:get(user_id, Context)),
        ?assert(is_binary(maps:get(invocation_id, Context)))
    after
        ok = erlang_adk:stop_agent(Agent),
        _ = erlang_adk_session:delete_session(?APP, ?USER, SessionId)
    end.

invalid_toolset_fails_agent_start() ->
    Name = unique_name("InvalidToolset"),
    Result = erlang_adk:spawn_agent(
               Name, #{provider => adk_llm_probe},
               [{adk_toolset, definitely_missing_toolset, ignored}]),
    ?assertMatch({error, _}, Result).

assert_model_saw_schema() ->
    receive
        {probe_generate, _History, Tools} ->
            ?assert(lists:any(
                      fun(#{<<"name">> := <<"dynamic_echo">>}) -> true;
                         (_) -> false
                      end, Tools))
    after 1000 ->
        ?assert(false)
    end.

receive_execution(ExpectedText) ->
    receive
        {dynamic_tool_executed, Worker, Args, Context} ->
            ?assert(is_pid(Worker)),
            ?assertEqual(ExpectedText, maps:get(<<"text">>, Args)),
            Context
    after 1000 ->
        ?assert(false)
    end.

unique_name(Prefix) ->
    Prefix ++ integer_to_list(erlang:unique_integer([positive])).

unique_binary(Prefix) ->
    iolist_to_binary([Prefix, "-",
                      integer_to_list(erlang:unique_integer([positive]))]).
