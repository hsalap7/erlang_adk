-module(adk_plugin_runner_integration_test).
-include_lib("eunit/include/eunit.hrl").
-include("adk_event.hrl").

-define(APP, <<"plugin-integration-app">>).
-define(USER, <<"plugin-user">>).

plugin_runner_integration_test_() ->
    {setup,
     fun setup/0,
     fun cleanup/1,
     [fun global_plugins_precede_local_callbacks/0,
      fun before_model_amendment_is_validated_and_executed/0,
      fun before_model_intervention_skips_local_and_provider/0,
      fun after_model_intervention_skips_local_after_callback/0,
      fun before_tool_amendment_is_validated_and_executed/0,
      fun tool_intervention_skips_local_before_and_execution/0,
      fun plugin_runtime_is_inherited_by_sub_agents/0,
      fun final_event_replacement_cannot_bypass_schema_boundary/0,
      fun connected_export_metadata_is_correlated_and_redacted/0]}.

setup() ->
    {ok, _} = application:ensure_all_started(erlang_adk),
    erlang_adk_session:init().

cleanup(_) ->
    persistent_term:erase({adk_plugin_integration_callback, target}),
    persistent_term:erase({adk_plugin_integration_tool, target}),
    case ets:whereis(adk_sessions) of
        undefined -> ok;
        _ -> ets:delete_all_objects(adk_sessions)
    end.

before_model_amendment_is_validated_and_executed() ->
    install_callback_target(),
    Amend = fun(Request) ->
        Memory = maps:get(memory, Request),
        AmendedMemory =
            [case Message of
                 #{role := user} ->
                     Message#{content => <<"amended prompt">>};
                 _ -> Message
             end || Message <- Memory],
        Request#{memory => AmendedMemory}
    end,
    Plugin = integration_plugin(
               #{before_model => {amend_fun, Amend}}),
    {ok, Agent} = spawn_probe_agent(
                    #{response => <<"amendment complete">>,
                      test_pid => self()}),
    Runner = runner(Agent, Plugin, #{}),
    try
        ?assertEqual(
           {ok, <<"amendment complete">>},
           adk_runner:run(
             Runner, ?USER, <<"model-amendment">>, <<"original prompt">>)),
        Events = drain_messages([]),
        [History | _] = [H || {probe_generate, H, _} <- Events],
        ?assert(lists:any(
                  fun(#{role := user,
                        content := <<"amended prompt">>}) -> true;
                     (_) -> false
                  end, History)),
        ?assertNot(lists:any(
                     fun(#{role := user,
                           content := <<"original prompt">>}) -> true;
                        (_) -> false
                     end, History))
    after
        stop_agent(Agent),
        clear_callback_target()
    end.

global_plugins_precede_local_callbacks() ->
    install_callback_target(),
    {ok, Agent} = spawn_probe_agent(#{response => <<"normal">>}),
    Runner = runner(Agent, observe_plugin(), #{}),
    try
        ?assertEqual(
           {ok, <<"normal">>},
           adk_runner:run(
             Runner, ?USER, <<"ordering">>, <<"hello">>)),
        Events = drain_messages([]),
        assert_before({integration_plugin, before_agent},
                      {integration_callback, before_agent}, Events),
        assert_before({integration_plugin, before_model},
                      {integration_callback, before_model}, Events),
        assert_before({integration_plugin, after_model},
                      {integration_callback, after_model}, Events),
        assert_before({integration_plugin, after_agent},
                      {integration_callback, after_agent}, Events),
        ?assert(lists:member({integration_plugin, before_run}, Events)),
        ?assert(lists:member({integration_plugin, after_run}, Events))
    after
        stop_agent(Agent),
        clear_callback_target()
    end.

before_model_intervention_skips_local_and_provider() ->
    install_callback_target(),
    Actions = #{before_model => {replace, {ok, <<"cached">>}}},
    Plugin = integration_plugin(Actions),
    {ok, Agent} = spawn_probe_agent(
                    #{response => <<"provider">>, test_pid => self()}),
    Runner = runner(Agent, Plugin, #{}),
    try
        ?assertEqual(
           {ok, <<"cached">>},
           adk_runner:run(
             Runner, ?USER, <<"before-model">>, <<"hello">>)),
        Events = drain_messages([]),
        ?assertNot(lists:member({integration_callback, before_model}, Events)),
        ?assert(lists:member({integration_callback, after_model}, Events)),
        ?assertNot(lists:any(
                     fun({probe_generate, _, _}) -> true;
                        (_) -> false
                     end, Events))
    after
        stop_agent(Agent),
        clear_callback_target()
    end.

after_model_intervention_skips_local_after_callback() ->
    install_callback_target(),
    Actions = #{after_model => {replace, {ok, <<"rewritten">>}}},
    Plugin = integration_plugin(Actions),
    {ok, Agent} = spawn_probe_agent(#{response => <<"provider">>}),
    Runner = runner(Agent, Plugin, #{}),
    try
        ?assertEqual(
           {ok, <<"rewritten">>},
           adk_runner:run(
             Runner, ?USER, <<"after-model">>, <<"hello">>)),
        Events = drain_messages([]),
        ?assert(lists:member({integration_callback, before_model}, Events)),
        ?assertNot(lists:member({integration_callback, after_model}, Events))
    after
        stop_agent(Agent),
        clear_callback_target()
    end.

tool_intervention_skips_local_before_and_execution() ->
    install_callback_target(),
    persistent_term:put({adk_plugin_integration_tool, target}, self()),
    Actions = #{before_tool => {replace, <<"plugin-tool-value">>}},
    Plugin = integration_plugin(Actions),
    {ok, Agent} = erlang_adk:spawn_agent(
                    <<"PluginToolAgent">>,
                    #{provider => adk_llm_probe, mode => tool_call,
                      call_name => <<"integration_tool">>,
                      call_args => #{<<"value">> => 1},
                      call_id => <<"call-integration">>,
                      response => <<"tool complete">>,
                      callbacks => [adk_plugin_integration_callback]},
                    [adk_plugin_integration_tool]),
    Runner = runner(Agent, Plugin, #{}),
    try
        ?assertEqual(
           {ok, <<"tool complete">>},
           adk_runner:run(
             Runner, ?USER, <<"tool-intervention">>, <<"use tool">>)),
        Events = drain_messages([]),
        ?assertNot(lists:member({integration_callback, before_tool}, Events)),
        ?assertNot(lists:member({integration_callback, on_tool_start}, Events)),
        ?assertNot(lists:any(
                     fun({integration_tool_executed, _}) -> true;
                        (_) -> false
                     end, Events)),
        assert_before({integration_plugin, after_tool},
                      {integration_callback, after_tool}, Events)
    after
        stop_agent(Agent),
        persistent_term:erase({adk_plugin_integration_tool, target}),
        clear_callback_target()
    end.

before_tool_amendment_is_validated_and_executed() ->
    install_callback_target(),
    persistent_term:put({adk_plugin_integration_tool, target}, self()),
    Amend = fun(Request) ->
        Request#{args => #{<<"value">> => 7}}
    end,
    Plugin = integration_plugin(
               #{before_tool => {amend_fun, Amend}}),
    {ok, Agent} = erlang_adk:spawn_agent(
                    <<"PluginToolAmendAgent">>,
                    #{provider => adk_llm_probe, mode => tool_call,
                      call_name => <<"integration_tool">>,
                      call_args => #{<<"value">> => 1},
                      call_id => <<"call-amendment">>,
                      response => <<"tool amendment complete">>,
                      callbacks => [adk_plugin_integration_callback]},
                    [adk_plugin_integration_tool]),
    Runner = runner(Agent, Plugin, #{}),
    try
        ?assertEqual(
           {ok, <<"tool amendment complete">>},
           adk_runner:run(
             Runner, ?USER, <<"tool-amendment">>, <<"use tool">>)),
        Events = drain_messages([]),
        ?assert(lists:member(
                  {integration_tool_executed,
                   #{<<"value">> => 7}}, Events)),
        ?assertNot(lists:member(
                     {integration_tool_executed,
                      #{<<"value">> => 1}}, Events))
    after
        stop_agent(Agent),
        persistent_term:erase({adk_plugin_integration_tool, target}),
        clear_callback_target()
    end.

plugin_runtime_is_inherited_by_sub_agents() ->
    {ok, Child} = erlang_adk:spawn_agent(
                    <<"PluginInheritedChild">>,
                    #{provider => adk_llm_probe,
                      response => <<"child response">>}, []),
    {ok, Root} = erlang_adk:spawn_agent(
                   <<"PluginInheritedRoot">>,
                   #{provider => adk_llm_probe,
                     mode => sub_agent_call,
                     call_name => <<"PluginInheritedChild">>,
                     sub_agents =>
                         #{<<"PluginInheritedChild">> => Child}}, []),
    Runner = runner(Root, observe_plugin(), #{}),
    try
        ?assertEqual(
           {ok, <<"delegation complete">>},
           adk_runner:run(
             Runner, ?USER, <<"plugin-delegation">>, <<"delegate">>)),
        Events = drain_messages([]),
        ?assertEqual(2, count_event(
                          {integration_plugin, before_agent}, Events)),
        %% The root model runs before and after its delegated tool response;
        %% the child model contributes the third callback.
        ?assertEqual(3, count_event(
                          {integration_plugin, before_model}, Events)),
        ?assertEqual(2, count_event(
                          {integration_plugin, after_agent}, Events))
    after
        stop_agent(Root),
        stop_agent(Child)
    end.

final_event_replacement_cannot_bypass_schema_boundary() ->
    Transform = fun(Event = #adk_event{is_final = true}) ->
                        Event#adk_event{content = <<"unvalidated">>};
                   (Event) -> Event
                end,
    Plugin = integration_plugin(
               #{on_event => {replace_fun, Transform}}),
    {ok, Agent} = spawn_probe_agent(#{response => <<"safe">>}),
    Runner = runner(Agent, Plugin, #{}),
    try
        ?assertEqual(
           {error, invalid_event_replacement_identity},
           adk_runner:run(
             Runner, ?USER, <<"final-event">>, <<"hello">>))
    after
        stop_agent(Agent)
    end.

connected_export_metadata_is_correlated_and_redacted() ->
    persistent_term:put({adk_plugin_integration_tool, target}, self()),
    {ok, Agent} = erlang_adk:spawn_agent(
                    <<"ObservedToolAgent">>,
                    #{provider => adk_llm_probe, mode => tool_call,
                      model => <<"probe-model">>,
                      call_name => <<"integration_tool">>,
                      call_args => #{}, call_id => <<"observed-call">>,
                      response => <<"observed complete">>},
                    [adk_plugin_integration_tool]),
    Exporter = #{id => <<"test-exporter">>,
                 module => adk_observability_test_exporter,
                 config => #{test_pid => self(), label => integration},
                 failure_policy => closed,
                 timeout_ms => 1000, max_heap_words => 100000},
    Observation = #{exporters => [Exporter], capture_content => false,
                    attributes => #{deployment => <<"test">>,
                                    authorization => <<"do-not-export">>}},
    Runner = runner(Agent, disabled, Observation),
    try
        ?assertEqual(
           {ok, <<"observed complete">>},
           adk_runner:run(
             Runner, ?USER, <<"observed-session">>, <<"use tool">>)),
        Messages = drain_messages([]),
        Envelopes = [Envelope ||
                     {exported, integration, Envelope} <- Messages],
        ?assert(length(Envelopes) > 5),
        LegacyEnvelopes =
            [Envelope || Envelope <- Envelopes,
                         maps:get(<<"schema_version">>, Envelope) =:= 1],
        Metadata = [maps:get(<<"metadata">>, Envelope)
                    || Envelope <- LegacyEnvelopes],
        ?assertEqual(1, length(lists:usort(
                                [maps:get(<<"trace_id">>, M)
                                 || M <- Metadata]))),
        ?assertEqual(1, length(lists:usort(
                                [maps:get(<<"run_id">>, M)
                                 || M <- Metadata]))),
        ?assertEqual(1, length(lists:usort(
                                [maps:get(<<"invocation_id">>, M)
                                 || M <- Metadata]))),
        lists:foreach(fun(M) ->
            ?assertEqual(<<"observed-session">>,
                         maps:get(<<"session">>, M)),
            ?assertEqual(<<"ObservedToolAgent">>,
                         maps:get(<<"agent">>, M)),
            ?assertEqual(<<"probe-model">>, maps:get(<<"model">>, M))
        end, Metadata),
        ?assert(lists:any(
                  fun(M) ->
                      maps:get(<<"tool">>, M) =:= <<"integration_tool">>
                      andalso maps:get(<<"call_id">>, M) =:=
                                  <<"observed-call">>
                  end, Metadata)),
        Encoded = jsx:encode(Envelopes),
        ?assertEqual(nomatch, binary:match(Encoded, <<"do-not-export">>)),
        ?assert(lists:all(
                  fun(Envelope) ->
                      maps:get(<<"content_captured">>, Envelope) =:= false
                  end, LegacyEnvelopes)),
        ?assert(lists:any(
                  fun(Envelope) ->
                      maps:get(<<"schema_version">>, Envelope) =:= 2
                  end, Envelopes)),
        ?assert(lists:all(
                  fun(Envelope) ->
                      not maps:is_key(<<"content">>, Envelope)
                  end, Envelopes))
    after
        stop_agent(Agent),
        persistent_term:erase({adk_plugin_integration_tool, target})
    end.

spawn_probe_agent(Extra) ->
    Base = #{provider => adk_llm_probe,
             callbacks => [adk_plugin_integration_callback]},
    erlang_adk:spawn_agent(
      <<"PluginProbeAgent">>, maps:merge(Base, Extra), []).

runner(Agent, Plugin, Observation) ->
    PluginOpts = case Plugin of
        disabled -> #{};
        _ -> #{plugins => [Plugin]}
    end,
    ObservationOpts = case map_size(Observation) of
        0 -> #{};
        _ -> #{observability => Observation}
    end,
    adk_runner:new(
      Agent, ?APP, erlang_adk_session,
      maps:merge(PluginOpts, ObservationOpts)).

observe_plugin() -> integration_plugin(#{}).

integration_plugin(Actions) ->
    #{id => <<"integration-plugin">>,
      module => adk_plugin_integration_plugin,
      mode => intervene, failure_policy => closed,
      timeout_ms => 1000, max_heap_words => 100000,
      config => #{test_pid => self(), actions => Actions}}.

install_callback_target() ->
    persistent_term:put({adk_plugin_integration_callback, target}, self()).

clear_callback_target() ->
    persistent_term:erase({adk_plugin_integration_callback, target}).

stop_agent(Agent) -> _ = catch erlang_adk:stop_agent(Agent), ok.

drain_messages(Acc) ->
    receive Message -> drain_messages([Message | Acc])
    after 30 -> lists:reverse(Acc)
    end.

assert_before(First, Second, Events) ->
    ?assert(position(First, Events) < position(Second, Events)).

position(Item, List) -> position(Item, List, 1).
position(Item, [Item | _], Index) -> Index;
position(Item, [_ | Rest], Index) -> position(Item, Rest, Index + 1);
position(Item, [], _Index) -> erlang:error({missing_event, Item}).

count_event(Item, Events) ->
    length([ok || Event <- Events, Event =:= Item]).
