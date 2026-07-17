-module(adk_plugin_builtin_test).
-include_lib("eunit/include/eunit.hrl").

global_instruction_amends_system_message_test() ->
    Request = #{config => #{provider => adk_llm_dummy},
                memory => [#{role => user, content => <<"hello">>},
                           #{role => system, content => <<"local">>}],
                tools => []},
    {ok, Pipeline} = adk_plugin_pipeline:compile([
        descriptor(<<"global">>, adk_plugin_global_instruction,
                   intervene,
                   #{instruction => <<"global">>, position => prepend})
    ]),
    {amend, Amended, _} = adk_plugin_pipeline:run(
                            Pipeline, before_model, #{}, Request),
    ?assert(lists:any(
              fun(#{role := system,
                    content := <<"global\n\nlocal">>}) -> true;
                 (_) -> false
              end, maps:get(memory, Amended))).

context_filter_preserves_system_and_latest_user_test() ->
    Memory = [#{role => user, content => <<"latest">>},
              #{role => agent, content => <<"answer">>},
              #{role => user, content => <<"old">>},
              #{role => system, content => <<"system">>}],
    Request = #{config => #{provider => adk_llm_dummy},
                memory => Memory, tools => []},
    {ok, Pipeline} = adk_plugin_pipeline:compile([
        descriptor(<<"filter">>, adk_plugin_context_filter,
                   intervene,
                   #{max_messages => 1,
                     include_roles => [agent],
                     preserve_system => true,
                     preserve_latest_user => true})
    ]),
    {amend, Amended, _} = adk_plugin_pipeline:run(
                            Pipeline, before_model, #{}, Request),
    ?assertEqual([#{role => user, content => <<"latest">>},
                  #{role => system, content => <<"system">>}],
                 maps:get(memory, Amended)).

metadata_logger_emits_no_content_test() ->
    {ok, _} = application:ensure_all_started(telemetry),
    HandlerId = {?MODULE, make_ref()},
    Parent = self(),
    ok = telemetry:attach(
           HandlerId, [erlang_adk, plugin, metadata],
           fun(Name, Measurements, Metadata, Pid) ->
               Pid ! {metadata_event, Name, Measurements, Metadata}
           end, Parent),
    {ok, Pipeline} = adk_plugin_pipeline:compile([
        descriptor(<<"metadata">>, adk_plugin_metadata_logger,
                   observe, #{id => <<"audit">>})
    ]),
    try
        {continue, <<"private content">>, _} =
            adk_plugin_pipeline:run(
              Pipeline, before_run,
              #{run_id => <<"run-1">>, api_key => <<"secret">>},
              <<"private content">>),
        receive
            {metadata_event, [erlang_adk, plugin, metadata],
             #{count := 1}, Metadata} ->
                ?assertEqual(before_run, maps:get(hook, Metadata)),
                Encoded = term_to_binary(Metadata),
                ?assertEqual(nomatch,
                             binary:match(Encoded, <<"private content">>)),
                ?assertEqual(nomatch,
                             binary:match(Encoded, <<"secret">>))
        after 1000 -> erlang:error(metadata_telemetry_timeout)
        end
    after
        telemetry:detach(HandlerId)
    end.

metadata_logger_hook_and_value_type_contract_test() ->
    {ok, _} = application:ensure_all_started(telemetry),
    HandlerId = {?MODULE, make_ref()},
    Parent = self(),
    ok = telemetry:attach(
           HandlerId, [erlang_adk, plugin, metadata],
           fun(_Name, _Measurements, Metadata, Pid) ->
               Pid ! {metadata_contract_event, Metadata}
           end, Parent),
    Context = #{<<"run_id">> => <<"run-contract">>,
                <<"tool">> => <<"weather">>,
                <<"secret">> => <<"must-not-be-observed">>},
    Cases = [
        {on_user_message, <<"private-binary">>, binary},
        {before_run, #{private => map}, map},
        {after_run, [private, list], list},
        {before_agent, {private, tuple}, tuple},
        {after_agent, private_atom, atom},
        {before_model, 42, number},
        {after_model, self(), other},
        {on_model_error, <<"private-model-error">>, binary},
        {before_tool, #{private => tool}, map},
        {after_tool, [private_tool], list},
        {on_tool_error, {private, tool_error}, tuple},
        {on_event, private_event, atom},
        {on_agent_error, 3.5, number},
        {on_run_error, fun() -> private end, other},
        {on_error, <<"private-error">>, binary}
    ],
    try
        lists:foreach(
          fun({Hook, Value, ExpectedType}) ->
              ?assertEqual(
                 observe,
                 apply(adk_plugin_metadata_logger, Hook,
                       [Context, Value,
                        #{id => <<"metadata-contract">>,
                          log_level => none}])),
              receive
                  {metadata_contract_event, Metadata} ->
                      ?assertEqual(Hook, maps:get(hook, Metadata)),
                      ?assertEqual(ExpectedType,
                                   maps:get(value_type, Metadata)),
                      ?assertEqual(<<"metadata-contract">>,
                                   maps:get(plugin_id, Metadata)),
                      ?assertEqual(<<"run-contract">>,
                                   maps:get(<<"run_id">>, Metadata)),
                      ?assertEqual(<<"weather">>,
                                   maps:get(<<"tool">>, Metadata)),
                      ?assertNot(maps:is_key(<<"secret">>, Metadata)),
                      ?assertEqual(
                         nomatch,
                         binary:match(term_to_binary(Metadata),
                                      <<"private">>)),
                      ?assertEqual(
                         nomatch,
                         binary:match(term_to_binary(Metadata),
                                      <<"must-not-be-observed">>))
              after 1000 ->
                  erlang:error(metadata_contract_timeout)
              end
          end, Cases)
    after
        telemetry:detach(HandlerId)
    end,
    ?assertEqual(
       observe,
       adk_plugin_metadata_logger:before_run(
         #{}, ok, #{log_level => debug})),
    ?assertError(
       invalid_metadata_logger_level,
       adk_plugin_metadata_logger:before_run(
         #{}, ok, #{log_level => verbose})).

reflect_retry_returns_bounded_guidance_test() ->
    {ok, Pipeline} = adk_plugin_pipeline:compile([
        descriptor(<<"retry">>, adk_plugin_reflect_retry,
                   intervene,
                   #{max_attempts => 2,
                     guidance => <<"fix arguments">>})
    ]),
    Failure = {error, {http_error, 503, <<"secret body">>}},
    {return, #{<<"adk_retry">> := Retry}, _} =
        adk_plugin_pipeline:run(
          Pipeline, on_tool_error, #{retry_attempt => 0}, Failure),
    ?assertEqual(true, maps:get(<<"retryable">>, Retry)),
    ?assertEqual(1, maps:get(<<"attempt">>, Retry)),
    ?assertEqual(2, maps:get(<<"max_attempts">>, Retry)),
    ?assertEqual(nomatch,
                 binary:match(term_to_binary(Retry), <<"secret body">>)),
    {continue, _SafeFailure, _} =
        adk_plugin_pipeline:run(
          Pipeline, on_tool_error, #{retry_attempt => 2}, Failure).

descriptor(Id, Module, Mode, Config) ->
    #{id => Id, module => Module, mode => Mode,
      failure_policy => closed, timeout_ms => 1000,
      max_heap_words => 100000, config => Config}.
