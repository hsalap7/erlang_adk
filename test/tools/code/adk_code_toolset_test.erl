-module(adk_code_toolset_test).
-include_lib("eunit/include/eunit.hrl").

compile_and_schema_test() ->
    {ok, Descriptor = {adk_toolset, adk_code_toolset, _}} =
        adk_code_toolset:new(config(#{})),
    {ok, [Schema]} = adk_toolset:schemas(Descriptor),
    ?assertEqual(<<"execute_code">>, maps:get(<<"name">>, Schema)),
    Params = maps:get(<<"parameters">>, Schema),
    Language = maps:get(<<"language">>, maps:get(<<"properties">>, Params)),
    ?assertEqual([<<"erlang">>, <<"python">>], maps:get(<<"enum">>, Language)),
    Caps = adk_code_toolset:capabilities(),
    ?assertEqual(true, maps:get(external_sandbox_required, Caps)),
    ?assertEqual(false, maps:get(in_process_execution, Caps)).

resolved_call_is_bounded_and_context_is_minimal_test() ->
    {ok, Compiled} = adk_code_toolset:compile(
                       config(#{context_keys =>
                                    [invocation_id, session_id, principal]})),
    Args = #{<<"language">> => <<"erlang">>,
             <<"code">> => <<"io:format(\"ok\").">>,
             <<"stdin">> => <<>>,
             <<"files">> =>
                 [#{<<"name">> => <<"src/input.txt">>,
                    <<"content">> => <<"input">>}]},
    Context = #{invocation_id => <<"inv-1">>,
                session_id => <<"sess-1">>,
                principal => #{<<"sub">> => <<"user-1">>},
                credential_ref => make_ref(),
                api_key => <<"secret">>},
    {ok, Call} = adk_code_toolset:resolved_call(
                   Compiled, <<"execute_code">>, Args, Context),
    ?assertEqual(false, maps:get(parallel_safe, Call)),
    ?assertEqual(1000, maps:get(timeout, Call)),
    {ok, Output} = (maps:get(execute, Call))(),
    ?assertEqual(<<"io:format(\"ok\").">>, maps:get(<<"stdout">>, Output)),
    receive
        {code_executor_request, Request, SafeContext} ->
            ?assertEqual(Args, Request),
            ?assertEqual(<<"inv-1">>, maps:get(<<"invocation_id">>, SafeContext)),
            ?assertEqual(<<"sess-1">>, maps:get(<<"session_id">>, SafeContext)),
            ?assertEqual(false, maps:is_key(<<"credential_ref">>, SafeContext)),
            ?assertEqual(false, maps:is_key(<<"api_key">>, SafeContext))
    after 1000 ->
        ?assert(false)
    end.

request_policy_rejects_unsafe_or_oversized_values_test() ->
    {ok, Compiled} = adk_code_toolset:compile(
                       config(#{max_code_bytes => 8,
                                max_file_bytes => 4,
                                max_total_file_bytes => 4})),
    ?assertEqual(
       {error, {invalid_code_request, language_not_allowed}},
       resolve(Compiled, #{<<"language">> => <<"ruby">>,
                           <<"code">> => <<"puts 1">>})),
    ?assertEqual(
       {error, {invalid_code_request, invalid_code}},
       resolve(Compiled, #{<<"language">> => <<"erlang">>,
                           <<"code">> => <<"123456789">>})),
    ?assertEqual(
       {error, {invalid_code_request, invalid_file}},
       resolve(Compiled, #{<<"language">> => <<"erlang">>,
                           <<"code">> => <<"ok.">>,
                           <<"files">> =>
                               [#{<<"name">> => <<"../escape">>,
                                  <<"content">> => <<"x">>}]})),
    ?assertEqual(
       {error, {invalid_code_request, invalid_file}},
       resolve(Compiled, #{<<"language">> => <<"erlang">>,
                           <<"code">> => <<"ok.">>,
                           <<"files">> =>
                               [#{<<"name">> => <<"..\\escape">>,
                                  <<"content">> => <<"x">>}]})),
    ?assertEqual(
       {error, {invalid_code_request, unknown_fields}},
       resolve(Compiled, #{<<"language">> => <<"erlang">>,
                           <<"code">> => <<"ok.">>,
                           <<"command">> => <<"/bin/sh">>})).

executor_failures_and_outputs_fail_closed_test() ->
    {ok, Compiled} = adk_code_toolset:compile(
                       config(#{max_output_bytes => 1024})),
    try
        ?assertEqual({error, invalid_code_output},
                     execute_code(Compiled, <<"invalid-output">>)),
        ?assertEqual({error, code_output_too_large},
                     execute_code(Compiled, <<"large-output">>)),
        ?assertMatch(
           {error, #{<<"code">> := <<"sandbox_error">>}},
           execute_code(Compiled, <<"crash">>)),
        {error, ProviderError} = execute_code(Compiled, <<"provider-error">>),
        Encoded = jsx:encode(ProviderError),
        ?assertEqual(nomatch, binary:match(Encoded, <<"must-not-leak">>)),
        ?assertNotEqual(nomatch, binary:match(Encoded, <<"[REDACTED]">>))
    after
        flush_executor_requests()
    end.

invalid_config_is_rejected_test() ->
    ?assertEqual({error, invalid_code_executor},
                 adk_code_toolset:compile(#{languages => [<<"erlang">>]})),
    ?assertEqual(
       {error, invalid_code_languages},
       adk_code_toolset:compile(config(#{languages => [<<"Erlang">>]}))),
    ?assertEqual(
       {error, invalid_code_limits},
       adk_code_toolset:compile(config(#{max_code_bytes => 0}))),
    ?assertEqual(
       {error, {unknown_code_toolset_config, [shell]}},
       adk_code_toolset:compile(config(#{shell => <<"/bin/sh">>}))).

resolve(Compiled, Args) ->
    adk_code_toolset:resolved_call(
      Compiled, <<"execute_code">>, Args, #{}).

execute_code(Compiled, Code) ->
    {ok, Call} = resolve(
                   Compiled,
                   #{<<"language">> => <<"erlang">>, <<"code">> => Code}),
    (maps:get(execute, Call))().

config(Overrides) ->
    maps:merge(
      #{executor => {adk_code_test_executor, self()},
        languages => [<<"erlang">>, <<"python">>],
        timeout => 1000},
      Overrides).

flush_executor_requests() ->
    receive
        {code_executor_request, _Request, _Context} ->
            flush_executor_requests()
    after 0 ->
        ok
    end.
