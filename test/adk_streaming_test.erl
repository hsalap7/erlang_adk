-module(adk_streaming_test).

-include_lib("eunit/include/eunit.hrl").
-include("adk_event.hrl").

-define(APP, <<"adk_streaming_test">>).
-define(USER, <<"stream-user">>).

streaming_test_() ->
    {setup,
     fun setup/0,
     fun cleanup/1,
     [fun text_stream_has_one_final_snapshot_case/0,
      fun stream_does_not_block_agent_mailbox_and_run_replays_case/0,
      fun content_stream_preserves_multimodal_output_case/0,
      fun direct_agent_preserves_canonical_content_case/0,
      fun stream_output_limit_fails_explicitly_case/0,
      fun invalid_streaming_options_fail_fast_case/0]}.

setup() ->
    {ok, _} = application:ensure_all_started(erlang_adk),
    ok = erlang_adk_session:init(),
    ok.

cleanup(_Setup) ->
    ok.

text_stream_has_one_final_snapshot_case() ->
    SessionId = unique(<<"text">>),
    {ok, Agent} = start_agent(
                    #{chunks => [<<"Erlang ">>, <<"streams">>],
                      test_pid => self()}),
    Runner = adk_runner:new(
               Agent, ?APP, erlang_adk_session,
               #{streaming_mode => text}),
    try
        ?assertEqual(
           {ok, <<"Erlang streams">>},
           adk_runner:run(Runner, ?USER, SessionId, <<"first">>)),
        receive
            {probe_stream_started, _Worker, text, FirstHistory, _Tools} ->
                ?assertEqual(<<"first">>, latest_user(FirstHistory))
        after 1000 ->
            ?assert(false)
        end,
        {ok, FirstSession} = erlang_adk_session:get_session(
                               ?APP, ?USER, SessionId),
        FirstEvents = maps:get(events, FirstSession),
        assert_text_stream_events(FirstEvents, <<"Erlang streams">>),

        %% Partial events are durable for clients but are excluded from the
        %% next model request; only the completed snapshot is conversation.
        ?assertEqual(
           {ok, <<"Erlang streams">>},
           adk_runner:run(Runner, ?USER, SessionId, <<"second">>)),
        receive
            {probe_stream_started, _Worker2, text, SecondHistory, _Tools2} ->
                AgentContents = [Content || #{role := agent,
                                              content := Content}
                                                <- SecondHistory],
                ?assertEqual([<<"Erlang streams">>], AgentContents),
                ?assertEqual(<<"second">>, latest_user(SecondHistory))
        after 1000 ->
            ?assert(false)
        end
    after
        stop_agent(Agent),
        delete_session(SessionId)
    end.

stream_does_not_block_agent_mailbox_and_run_replays_case() ->
    SessionId = unique(<<"run">>),
    StreamRef = make_ref(),
    {ok, Agent} = start_agent(
                    #{chunks => [<<"light">>, <<"weight">>],
                      test_pid => self(),
                      block_after_chunk => 1,
                      stream_ref => StreamRef}),
    Runner = adk_runner:new(
               Agent, ?APP, erlang_adk_session,
               #{streaming_mode => text, run_timeout => 5000}),
    try
        {ok, RunId} = adk_run:start(
                        Runner, ?USER, SessionId, <<"concurrent">>,
                        #{retention_ms => 2000}),
        ok = adk_run:subscribe(RunId),
        ProviderWorker = receive
            {probe_stream_blocked, Worker, StreamRef} -> Worker
        after 1000 ->
            ?assert(false)
        end,

        %% Provider I/O belongs to the independently supervised invocation
        %% worker. The agent gen_server remains responsive while it is blocked.
        ?assertMatch({ok, _, _, _, _}, adk_agent:get_runtime(Agent)),
        ProviderWorker ! {continue_stream, StreamRef},
        ?assertEqual(
           {completed, <<"lightweight">>},
           adk_run:await(RunId, 2000)),

        {Events, Terminal} = collect_run(RunId, [], undefined),
        ?assertEqual({completed, <<"lightweight">>}, Terminal),
        PartialContents = [Content || #adk_event{partial = true,
                                                 content = Content} <- Events],
        FinalContents = [Content || #adk_event{is_final = true,
                                               content = Content} <- Events],
        ?assertEqual([<<"light">>, <<"weight">>], PartialContents),
        ?assertEqual([<<"lightweight">>], FinalContents),
        ?assertEqual(4, length(Events)),
        receive
            {adk_run_terminal, RunId, _Seq, _Other} -> ?assert(false)
        after 20 ->
            ok
        end
    after
        stop_agent(Agent),
        delete_session(SessionId)
    end.

content_stream_preserves_multimodal_output_case() ->
    SessionId = unique(<<"content">>),
    {ok, Text1} = adk_content:text(<<"look ">>),
    {ok, Text2} = adk_content:text(<<"here">>),
    {ok, Inline} = adk_content:inline_data(<<"image/png">>, <<1, 2, 3>>),
    {ok, Delta1} = adk_content:new([Text1]),
    {ok, Delta2} = adk_content:new([Text2, Inline]),
    {ok, Expected} = adk_content:new([
                       Text1#{<<"text">> => <<"look here">>}, Inline]),
    {ok, Agent} = start_agent(
                    #{content_chunks => [Delta1, Delta2],
                      test_pid => self()}),
    Runner = adk_runner:new(
               Agent, ?APP, erlang_adk_session,
               #{streaming_mode => content}),
    try
        ?assertEqual(
           {ok, Expected},
           adk_runner:run(Runner, ?USER, SessionId, Delta2)),
        receive
            {probe_stream_started, _Worker, content, History, _Tools} ->
                ?assertEqual(Delta2, latest_user(History))
        after 1000 ->
            ?assert(false)
        end,
        {ok, Session} = erlang_adk_session:get_session(
                          ?APP, ?USER, SessionId),
        Events = maps:get(events, Session),
        Partial = [Content || #adk_event{partial = true,
                                         content = Content} <- Events],
        Final = [Content || #adk_event{is_final = true,
                                       content = Content} <- Events],
        ?assertEqual([Delta1, Delta2], Partial),
        ?assertEqual([Expected], Final),
        lists:foreach(
          fun(Event) ->
              {ok, Encoded} = adk_event:encode(Event),
              ?assertEqual({ok, Event},
                           adk_event:decode(
                             jsx:decode(jsx:encode(Encoded), [return_maps])))
          end,
          Events)
    after
        stop_agent(Agent),
        delete_session(SessionId)
    end.

direct_agent_preserves_canonical_content_case() ->
    {ok, PromptText} = adk_content:text(<<"describe">>),
    {ok, PromptImage} = adk_content:inline_data(
                          <<"image/png">>, <<10, 20, 30>>),
    {ok, Prompt} = adk_content:new([PromptText, PromptImage]),
    {ok, ResponseText} = adk_content:text(<<"a tiny image">>),
    {ok, Response} = adk_content:new([ResponseText]),
    {ok, Agent} = start_agent(
                    #{response => Response, test_pid => self()}),
    try
        ?assertEqual({ok, Response}, erlang_adk:prompt(Agent, Prompt)),
        receive
            {probe_generate, _ProviderWorker, History, _Tools} ->
                ?assertEqual(Prompt, latest_user(History))
        after 1000 ->
            ?assert(false)
        end
    after
        stop_agent(Agent)
    end.

stream_output_limit_fails_explicitly_case() ->
    SessionId = unique(<<"limit">>),
    {ok, Agent} = start_agent(#{chunks => [<<"five!">>]}),
    Runner = adk_runner:new(
               Agent, ?APP, erlang_adk_session,
               #{streaming_mode => text,
                 max_stream_output_bytes => 4}),
    try
        ?assertEqual(
           {error,
            {adk_failure,
             #{component => llm_provider, operation => stream,
               class => throw, reason => stream_output_limit_exceeded}}},
           adk_runner:run(Runner, ?USER, SessionId, <<"bounded">>)),
        {ok, Session} = erlang_adk_session:get_session(
                          ?APP, ?USER, SessionId),
        ?assertEqual([], [Event || #adk_event{partial = true} = Event
                                    <- maps:get(events, Session)])
    after
        stop_agent(Agent),
        delete_session(SessionId)
    end.

invalid_streaming_options_fail_fast_case() ->
    {ok, Agent} = start_agent(#{}),
    try
        ?assertError(
           {invalid_streaming_mode, live},
           adk_runner:new(
             Agent, ?APP, erlang_adk_session,
             #{streaming_mode => live})),
        ?assertError(
           {invalid_max_stream_output_bytes, 0},
           adk_runner:new(
             Agent, ?APP, erlang_adk_session,
             #{max_stream_output_bytes => 0})),
        ?assertError(
           {invalid_max_stream_output_bytes, 67108865},
           adk_runner:new(
             Agent, ?APP, erlang_adk_session,
             #{max_stream_output_bytes => 67108865}))
    after
        stop_agent(Agent)
    end.

assert_text_stream_events(Events, ExpectedFinal) ->
    PartialContents = [Content || #adk_event{partial = true,
                                             content = Content} <- Events],
    FinalContents = [Content || #adk_event{is_final = true,
                                           content = Content} <- Events],
    ?assertEqual([<<"Erlang ">>, <<"streams">>], PartialContents),
    ?assertEqual([ExpectedFinal], FinalContents),
    ?assertEqual(4, length(Events)).

collect_run(RunId, Events, Terminal) ->
    receive
        {adk_run_event, RunId, _Seq, Event} ->
            collect_run(RunId, [Event | Events], Terminal);
        {adk_run_terminal, RunId, _Seq, Outcome} ->
            {lists:reverse(Events), Outcome}
    after 2000 ->
        ?assert(false)
    end.

latest_user(History) ->
    Users = [Content || #{role := user, content := Content} <- History],
    lists:last(Users).

start_agent(Options) ->
    Name = binary_to_list(unique(<<"StreamAgent">>)),
    erlang_adk:spawn_agent(
      Name, Options#{provider => adk_llm_stream_probe}, []).

stop_agent(Agent) ->
    _ = catch erlang_adk:stop_agent(Agent),
    ok.

delete_session(SessionId) ->
    _ = erlang_adk_session:delete_session(?APP, ?USER, SessionId),
    ok.

unique(Prefix) ->
    Suffix = integer_to_binary(
               erlang:unique_integer([positive, monotonic])),
    <<Prefix/binary, "-", Suffix/binary>>.
