-module(adk_toolset_test).

-include_lib("eunit/include/eunit.hrl").

-define(APP, <<"toolset_app">>).
-define(USER, <<"toolset_user">>).

toolset_test_() ->
    {setup,
     fun setup/0,
     fun(_State) -> ok end,
     [fun descriptor_schema_and_resolution/0,
      fun descriptor_catalog_is_compiled_once/0,
      fun module_catalog_is_compiled_once_per_code_version/0,
      fun explicit_refresh_rebuilds_dynamic_catalog/0,
      fun duplicate_names_are_rejected_across_tool_entries/0,
      fun duplicate_names_identify_both_schema_sources/0,
      fun invalid_schema_identifies_catalog_source/0,
      fun resolved_confirmation_metadata_is_internal_and_validated/0,
      fun preflight_defers_live_dynamic_resolution/0,
      fun duplicate_tool_and_sub_agent_names_fail_at_spawn/0,
      fun invalid_arguments_are_rejected_before_resolution/0,
      fun invalid_direct_arguments_skip_tool_callbacks/0,
      fun invalid_runner_arguments_skip_tool_callbacks/0,
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

descriptor_catalog_is_compiled_once() ->
    {ok, Descriptor} = adk_toolset:new(
                         adk_test_toolset, {counted, self()}),
    assert_schema_reads(toolset_schema_read, 1),
    {ok, [_]} = adk_toolset:schemas(Descriptor),
    {ok, [_]} = adk_toolset:schemas(Descriptor),
    {ok, [_]} = adk_toolset:expand_tools([Descriptor]),
    Args = #{<<"text">> => <<"cached">>},
    {ok, {resolved, _}} = adk_toolset:resolve(
                            [Descriptor], <<"dynamic_echo">>, Args, #{}),
    {ok, {resolved, _}} = adk_toolset:resolve(
                            [Descriptor], <<"dynamic_echo">>, Args, #{}),
    assert_schema_reads(toolset_schema_read, 0).

module_catalog_is_compiled_once_per_code_version() ->
    ok = adk_catalog_counting_tool:set_target(self()),
    try
        {ok, [Schema]} = adk_toolset:expand_tools(
                           [adk_catalog_counting_tool]),
        ?assertEqual(<<"catalog_counting_tool">>,
                     maps:get(<<"name">>, Schema)),
        {ok, [_]} = adk_toolset:expand_tools([adk_catalog_counting_tool]),
        Args = #{<<"value">> => <<"cached">>},
        {ok, {module, adk_catalog_counting_tool}} =
            adk_toolset:resolve(
              [adk_catalog_counting_tool], <<"catalog_counting_tool">>,
              Args, #{}),
        {ok, {module, adk_catalog_counting_tool}} =
            adk_toolset:resolve(
              [adk_catalog_counting_tool], <<"catalog_counting_tool">>,
              Args, #{}),
        assert_schema_reads(module_schema_read, 1)
    after
        ok = adk_catalog_counting_tool:clear_target()
    end.

explicit_refresh_rebuilds_dynamic_catalog() ->
    CatalogPid = spawn(fun() -> catalog_source_loop(<<"dynamic_echo_v1">>) end),
    Handle = {mutable, CatalogPid, self()},
    try
        {ok, V1} = adk_toolset:new(adk_test_toolset, Handle),
        {ok, [#{<<"name">> := <<"dynamic_echo_v1">>}]} =
            adk_toolset:schemas(V1),
        ok = set_catalog_name(CatalogPid, <<"dynamic_echo_v2">>),
        %% A catalog is a stable model contract until callers explicitly
        %% refresh it. Execution still observes the live backend and therefore
        %% fails closed if the advertised operation disappeared.
        {ok, [#{<<"name">> := <<"dynamic_echo_v1">>}]} =
            adk_toolset:schemas(V1),
        Args = #{<<"text">> => <<"versioned">>},
        ?assertEqual(
           {error, tool_catalog_changed},
           adk_toolset:resolve(
             [V1], <<"dynamic_echo_v1">>, Args, #{})),
        ?assertEqual(
           {error, not_found},
           adk_toolset:resolve(
             [V1], <<"dynamic_echo_v2">>, Args, #{})),
        {ok, V2} = adk_toolset:refresh(V1),
        {ok, [#{<<"name">> := <<"dynamic_echo_v2">>}]} =
            adk_toolset:schemas(V2),
        ?assertMatch(
           {ok, {resolved, _}},
           adk_toolset:resolve(
             [V2], <<"dynamic_echo_v2">>, Args, #{}))
    after
        CatalogPid ! stop
    end.

duplicate_names_are_rejected_across_tool_entries() ->
    {ok, Descriptor} = adk_toolset:new(adk_test_toolset, self()),
    ?assertEqual(
       {error, {duplicate_tool_name, <<"dynamic_echo">>,
                {toolset, 1, adk_test_toolset, 1},
                {toolset, 2, adk_test_toolset, 1}}},
       adk_toolset:expand_tools([Descriptor, Descriptor])).

duplicate_names_identify_both_schema_sources() ->
    ?assertEqual(
       {error, {duplicate_tool_name, <<"dynamic_echo">>,
                {toolset, adk_test_toolset, 1},
                {toolset, adk_test_toolset, 2}}},
       adk_toolset:new(adk_test_toolset, {duplicate, self()})).

invalid_schema_identifies_catalog_source() ->
    ?assertEqual(
       {error,
        {invalid_tool_schema,
         {toolset, adk_test_toolset, 1, <<"broken_dynamic_tool">>},
         {invalid_tool_parameter_schema,
          {invalid_json_schema, [<<"type">>], unknown_type}}}},
       adk_toolset:new(adk_test_toolset, {invalid_schema, self()})).

resolved_confirmation_metadata_is_internal_and_validated() ->
    Confirmation = #{required => true,
                     hint => <<"Approve the external side effect">>},
    {ok, Descriptor} = adk_toolset:new(
                         adk_test_toolset,
                         {confirmation, self(), Confirmation}),
    {ok, [Schema]} = adk_toolset:expand_tools([Descriptor]),
    ?assertEqual(false, maps:is_key(confirmation, Schema)),
    ?assertEqual(false, maps:is_key(<<"confirmation">>, Schema)),
    Args = #{<<"text">> => <<"confirm">>},
    {ok, {resolved, Call}} = adk_toolset:resolve(
                               [Descriptor], <<"dynamic_echo">>,
                               Args, #{}),
    ?assertEqual(Confirmation, maps:get(confirmation, Call)),
    {ok, InvalidDescriptor} = adk_toolset:new(
                                adk_test_toolset,
                                {confirmation, self(),
                                 #{required => true,
                                   unknown => unsafe}}),
    ?assertEqual(
       {error, invalid_resolved_tool_call},
       adk_toolset:resolve(
         [InvalidDescriptor], <<"dynamic_echo">>, Args, #{})).

preflight_defers_live_dynamic_resolution() ->
    {ok, Descriptor} = adk_toolset:new(
                         adk_test_toolset, {resolution_probe, self()}),
    Args = #{<<"text">> => <<"preflight">>},
    Context = #{invocation_id => <<"preflight-invocation">>},
    {ok, Target} = adk_toolset:preflight(
                     [Descriptor], <<"dynamic_echo">>, Args),
    receive {dynamic_tool_resolved, _, _} -> ?assert(false)
    after 0 -> ok
    end,
    {ok, {resolved, _Call}} = adk_toolset:materialize(
                                Target, <<"dynamic_echo">>, Args, Context),
    receive
        {dynamic_tool_resolved, Args, Context} -> ok
    after 1000 -> ?assert(false)
    end,
    ?assertMatch(
       {error, {invalid_tool_arguments, _}},
       adk_toolset:preflight([Descriptor], <<"dynamic_echo">>, #{})),
    receive {dynamic_tool_resolved, _, _} -> ?assert(false)
    after 0 -> ok
    end.

duplicate_tool_and_sub_agent_names_fail_at_spawn() ->
    Name = unique_name("DuplicateToolSubAgent"),
    ?assertMatch(
       {error, _},
       erlang_adk:spawn_agent(
         Name,
         #{provider => adk_llm_probe,
           sub_agents => #{<<"dummy_tool">> => self()}},
         [dummy_tool])).

invalid_arguments_are_rejected_before_resolution() ->
    {ok, Descriptor} = adk_toolset:new(adk_test_toolset, self()),
    Context = #{invocation_id => <<"invalid-args">>},
    ?assertMatch(
       {error, {invalid_tool_arguments,
                {schema_validation_failed, [],
                 {required_property, <<"text">>}}}},
       adk_toolset:resolve(
         [Descriptor], <<"dynamic_echo">>, #{}, Context)),
    ?assertMatch(
       {error, {invalid_tool_arguments,
                {schema_validation_failed, [<<"text">>],
                 {expected_type, <<"string">>}}}},
       adk_toolset:resolve(
         [Descriptor], <<"dynamic_echo">>,
         #{<<"text">> => 42}, Context)),
    ?assertMatch(
       {error, {invalid_tool_arguments,
                {schema_validation_failed, [<<"extra">>],
                 additional_property}}},
       adk_toolset:resolve(
         [Descriptor], <<"dynamic_echo">>,
         #{<<"text">> => <<"valid">>, <<"extra">> => true},
         Context)),
    Response = adk_toolset:invalid_arguments_response(
                 {invalid_tool_arguments,
                  {schema_validation_failed, [],
                   {required_property, <<"text">>}}}),
    ?assertMatch(
       #{<<"success">> := false,
         <<"error">> :=
             #{<<"type">> := <<"invalid_tool_arguments">>,
               <<"validation">> :=
                   #{<<"kind">> := <<"schema_validation_failed">>}}},
       Response),
    receive
        {dynamic_tool_executed, _Worker, _Args, _ExecutionContext} ->
            ?assert(false)
    after 0 ->
        ok
    end.

invalid_direct_arguments_skip_tool_callbacks() ->
    {ok, Descriptor} = adk_toolset:new(adk_test_toolset, self()),
    Name = unique_name("InvalidDirectArguments"),
    persistent_term:put({adk_callback_lifecycle_test, target}, self()),
    {ok, Agent} = erlang_adk:spawn_agent(
                    Name,
                    #{provider => adk_llm_probe,
                      mode => tool_call,
                      call_name => <<"dynamic_echo">>,
                      call_args => #{},
                      response => <<"corrected">>,
                      callbacks => [adk_callback_lifecycle_test]},
                    [Descriptor]),
    try
        ?assertEqual({ok, <<"corrected">>},
                     erlang_adk:prompt(Agent, <<"invalid call">>)),
        assert_no_tool_callbacks(receive_callback_events([])),
        assert_not_executed()
    after
        ok = erlang_adk:stop_agent(Agent),
        persistent_term:erase({adk_callback_lifecycle_test, target})
    end.

invalid_runner_arguments_skip_tool_callbacks() ->
    {ok, Descriptor} = adk_toolset:new(adk_test_toolset, self()),
    Name = unique_name("InvalidRunnerArguments"),
    SessionId = unique_binary("invalid-runner-arguments"),
    persistent_term:put({adk_callback_lifecycle_test, target}, self()),
    {ok, Agent} = erlang_adk:spawn_agent(
                    Name,
                    #{provider => adk_llm_probe,
                      mode => tool_call,
                      call_name => <<"dynamic_echo">>,
                      call_args => #{<<"text">> => 42},
                      response => <<"corrected">>,
                      callbacks => [adk_callback_lifecycle_test]},
                    [Descriptor]),
    Runner = adk_runner:new(
               Agent, ?APP, erlang_adk_session,
               #{run_timeout => 3000,
                 tool_execution =>
                     #{mode => parallel, max_concurrency => 2,
                       tool_timeout => 1000}}),
    try
        ?assertEqual(
           {ok, <<"corrected">>},
           adk_runner:run(
             Runner, ?USER, SessionId, <<"invalid call">>)),
        assert_no_tool_callbacks(receive_callback_events([])),
        assert_not_executed()
    after
        ok = erlang_adk:stop_agent(Agent),
        persistent_term:erase({adk_callback_lifecycle_test, target}),
        _ = erlang_adk_session:delete_session(
              ?APP, ?USER, SessionId)
    end.

receive_callback_events(Acc) ->
    receive
        {callback, Event} -> receive_callback_events([Event | Acc])
    after 100 ->
        Acc
    end.

assert_no_tool_callbacks(Events) ->
    ToolCallbacks = [on_tool_start, before_tool,
                     after_tool, on_tool_end],
    ?assertEqual([], [Event || Event <- Events,
                              lists:member(Event, ToolCallbacks)]).

assert_not_executed() ->
    receive
        {dynamic_tool_executed, _Worker, _Args, _ExecutionContext} ->
            ?assert(false)
    after 0 ->
        ok
    end.

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
        ?assert(is_binary(maps:get(invocation_id, Context))),
        ?assertEqual(false, maps:is_key('$adk_agent_path', Context))
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

assert_schema_reads(Message, Expected) ->
    ?assertEqual(Expected, collect_schema_reads(Message, 0)).

collect_schema_reads(Message, Count) ->
    receive
        Message -> collect_schema_reads(Message, Count + 1)
    after 0 ->
        Count
    end.

catalog_source_loop(Name) ->
    receive
        {get_catalog_name, From, Ref} ->
            From ! {catalog_name, Ref, Name},
            catalog_source_loop(Name);
        {set_catalog_name, From, Ref, NewName} ->
            From ! {catalog_name_set, Ref},
            catalog_source_loop(NewName);
        stop -> ok
    end.

set_catalog_name(CatalogPid, Name) ->
    Ref = make_ref(),
    CatalogPid ! {set_catalog_name, self(), Ref, Name},
    receive
        {catalog_name_set, Ref} -> ok
    after 1000 ->
        error(catalog_source_timeout)
    end.

unique_name(Prefix) ->
    Prefix ++ integer_to_list(erlang:unique_integer([positive])).

unique_binary(Prefix) ->
    iolist_to_binary([Prefix, "-",
                      integer_to_list(erlang:unique_integer([positive]))]).
