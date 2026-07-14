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
