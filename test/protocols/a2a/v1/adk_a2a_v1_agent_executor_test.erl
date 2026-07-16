-module(adk_a2a_v1_agent_executor_test).

-include_lib("eunit/include/eunit.hrl").

-define(ENV_KEY, a2a_v1_agent_name).

agent_executor_test_() ->
    {setup,
     fun setup/0,
     fun cleanup/1,
     [fun missing_configuration_is_reported/0,
      fun missing_registered_agent_is_reported/0,
      fun text_parts_are_joined_and_prompted/0,
      fun message_without_text_is_rejected/0]}.

setup() ->
    {ok, _} = application:ensure_all_started(erlang_adk),
    Previous = application:get_env(erlang_adk, ?ENV_KEY),
    ok = application:unset_env(erlang_adk, ?ENV_KEY),
    Previous.

cleanup(Previous) ->
    restore_env(Previous),
    flush_probe_messages(),
    ok.

missing_configuration_is_reported() ->
    ok = application:unset_env(erlang_adk, ?ENV_KEY),
    ?assertEqual(
       {failed, agent_not_configured},
       execute(message([#{<<"text">> => <<"hello">>}]))),
    ok = application:set_env(erlang_adk, ?ENV_KEY, not_a_binary),
    ?assertEqual(
       {failed, agent_not_configured},
       execute(message([#{<<"text">> => <<"hello">>}]))).

missing_registered_agent_is_reported() ->
    Name = unique_name(<<"A2AMissingAgent">>),
    ok = application:set_env(erlang_adk, ?ENV_KEY, Name),
    ?assertEqual(
       {failed, agent_not_found},
       execute(message([#{<<"text">> => <<"hello">>}]))).

text_parts_are_joined_and_prompted() ->
    Name = unique_name(<<"A2AExecutorAgent">>),
    {ok, Agent} = erlang_adk:spawn_agent(
                    Name,
                    #{provider => adk_llm_probe,
                      test_pid => self(),
                      response => <<"executor response">>},
                    []),
    try
        ok = application:set_env(erlang_adk, ?ENV_KEY, Name),
        Parts = [#{<<"text">> => <<"first line">>},
                 #{<<"data">> => <<"ignored">>},
                 #{<<"text">> => <<"second line">>}],
        ?assertEqual(
           {ok, <<"executor response">>},
           execute(message(Parts))),
        receive
            {probe_generate, History, []} ->
                Latest = lists:last(History),
                ?assertEqual(user, maps:get(role, Latest)),
                ?assertEqual(<<"first line\nsecond line">>,
                             maps:get(content, Latest))
        after 1000 ->
            ?assert(false)
        end
    after
        ok = erlang_adk:stop_agent(Agent)
    end.

message_without_text_is_rejected() ->
    Name = unique_name(<<"A2ANoTextAgent">>),
    {ok, Agent} = erlang_adk:spawn_agent(
                    Name, #{provider => adk_llm_probe,
                            test_pid => self()}, []),
    try
        ok = application:set_env(erlang_adk, ?ENV_KEY, Name),
        ?assertEqual({error, text_input_required}, execute(message([]))),
        ?assertEqual(
           {error, text_input_required},
           execute(message([#{<<"data">> => <<"not text">>}]))),
        receive
            {probe_generate, _, _} -> ?assert(false)
        after 0 ->
            ok
        end
    after
        ok = erlang_adk:stop_agent(Agent)
    end.

execute(Message) ->
    adk_a2a_v1_agent_executor:execute(
      #{message => Message}, fun(_Event) -> ok end).

message(Parts) ->
    #{<<"parts">> => Parts}.

unique_name(Prefix) ->
    Suffix = integer_to_binary(
               erlang:unique_integer([positive, monotonic])),
    <<Prefix/binary, Suffix/binary>>.

restore_env(undefined) ->
    application:unset_env(erlang_adk, ?ENV_KEY);
restore_env({ok, Value}) ->
    application:set_env(erlang_adk, ?ENV_KEY, Value).

flush_probe_messages() ->
    receive
        {probe_generate, _, _} -> flush_probe_messages()
    after 0 ->
        ok
    end.
