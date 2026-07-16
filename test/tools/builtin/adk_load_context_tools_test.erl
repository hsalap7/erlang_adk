-module(adk_load_context_tools_test).

-include_lib("eunit/include/eunit.hrl").

schema_and_capability_contracts_test() ->
    ArtifactSchema = adk_load_artifacts_tool:schema(),
    ArtifactParameters = maps:get(<<"parameters">>, ArtifactSchema),
    ArtifactProperty = maps:get(
                         <<"artifacts">>,
                         maps:get(<<"properties">>, ArtifactParameters)),
    ?assertEqual(<<"load_artifacts">>, maps:get(<<"name">>, ArtifactSchema)),
    ?assertEqual([<<"artifacts">>],
                 maps:get(<<"required">>, ArtifactParameters)),
    ?assertEqual(1, maps:get(<<"minItems">>, ArtifactProperty)),
    ?assertEqual(8, maps:get(<<"maxItems">>, ArtifactProperty)),
    ?assertEqual([artifact_attach],
                 adk_load_artifacts_tool:context_capabilities()),

    MemorySchema = adk_load_memory_tool:schema(),
    MemoryParameters = maps:get(<<"parameters">>, MemorySchema),
    LimitProperty = maps:get(
                      <<"limit">>,
                      maps:get(<<"properties">>, MemoryParameters)),
    ?assertEqual(<<"load_memory">>, maps:get(<<"name">>, MemorySchema)),
    ?assertEqual([<<"query">>], maps:get(<<"required">>, MemoryParameters)),
    ?assertEqual(1, maps:get(<<"minimum">>, LimitProperty)),
    ?assertEqual(20, maps:get(<<"maximum">>, LimitProperty)),
    ?assertEqual([memory_search],
                 adk_load_memory_tool:context_capabilities()).

artifact_request_validation_test() ->
    Context = #{},
    ?assertEqual(
       {error, invalid_artifact_attachment_request},
       adk_load_artifacts_tool:execute(#{}, Context)),
    ?assertEqual(
       {error, invalid_artifact_attachment_request},
       adk_load_artifacts_tool:execute(
         #{<<"artifacts">> => not_a_list}, Context)),
    ?assertEqual(
       {error, invalid_artifact_attachment_request},
       adk_load_artifacts_tool:execute(
         #{<<"artifacts">> => lists:duplicate(9, #{<<"name">> => <<"a">>})},
         Context)),
    ?assertEqual(
       {error, invalid_artifact_attachment_request},
       adk_load_artifacts_tool:execute(
         #{<<"artifacts">> => [#{<<"name">> => atom_name}]}, Context)),
    ?assertEqual(
       {error, invalid_artifact_version},
       adk_load_artifacts_tool:execute(
         #{<<"artifacts">> =>
               [#{<<"name">> => <<"a">>, <<"version">> => 0}]},
         Context)),
    ?assertEqual(
       {error, invalid_artifact_version},
       adk_load_artifacts_tool:execute(
         #{<<"artifacts">> =>
               [#{<<"name">> => <<"a">>, <<"version">> => <<"oldest">>}]},
         Context)).

artifact_success_is_sanitized_and_ordered_test() ->
    First = #{name => <<"one.txt">>, version => 3,
              mime_type => <<"text/plain">>, digest => <<"digest-one">>,
              size => 3, data => <<"secret-one">>,
              metadata => #{private => <<"secret-metadata">>}},
    Second = #{name => <<"two.txt">>, version => 1,
               mime_type => <<"text/plain">>},
    with_fake_capability(
      [{ok, First}, {ok, Second}],
      fun(Context, Pid) ->
          Args = #{<<"artifacts">> =>
                       [#{<<"name">> => <<"one.txt">>,
                          <<"version">> => <<"latest">>},
                        #{<<"name">> => <<"two.txt">>,
                          <<"version">> => 1}]},
          ?assertEqual(
             {ok, #{<<"success">> => true,
                    <<"attachments">> =>
                        [#{<<"name">> => <<"one.txt">>,
                           <<"version">> => 3,
                           <<"mime_type">> => <<"text/plain">>,
                           <<"digest">> => <<"digest-one">>,
                           <<"size">> => 3},
                         #{<<"name">> => <<"two.txt">>,
                           <<"version">> => 1,
                           <<"mime_type">> => <<"text/plain">>}]}},
             adk_load_artifacts_tool:execute(Args, Context)),
          ?assertEqual(
             [artifact_request(Pid, <<"one.txt">>, latest),
              artifact_request(Pid, <<"two.txt">>, 1)],
             receive_capability_requests(Pid, 2, []))
      end).

artifact_error_and_invalid_reply_contract_test() ->
    Attached = #{name => <<"attached.txt">>, version => 2,
                 mime_type => <<"text/plain">>, digest => <<"digest">>,
                 size => 8},
    with_fake_capability(
      [{ok, Attached}, {error, not_found}],
      fun(Context, _Pid) ->
          ?assertEqual(
             {ok, #{<<"success">> => false,
                    <<"error">> => <<"not_found">>,
                    <<"attachments">> =>
                        [#{<<"name">> => <<"attached.txt">>,
                           <<"version">> => 2,
                           <<"mime_type">> => <<"text/plain">>,
                           <<"digest">> => <<"digest">>,
                           <<"size">> => 8}]}},
             adk_load_artifacts_tool:execute(
               #{<<"artifacts">> =>
                     [#{<<"name">> => <<"attached.txt">>},
                      #{<<"name">> => <<"missing.txt">>}]},
               Context))
      end),
    with_fake_capability(
      [{error, {backend, unavailable}}],
      fun(Context, _Pid) ->
          ?assertEqual(
             {ok, #{<<"success">> => false,
                    <<"error">> => <<"artifact_operation_failed">>,
                    <<"attachments">> => []}},
             adk_load_artifacts_tool:execute(
               #{<<"artifacts">> => [#{<<"name">> => <<"a.txt">>}]},
               Context))
      end),
    with_fake_capability(
      [unexpected_reply],
      fun(Context, _Pid) ->
          ?assertEqual(
             {error, {invalid_artifact_service_reply, unexpected_reply}},
             adk_load_artifacts_tool:execute(
               #{<<"artifacts">> => [#{<<"name">> => <<"a.txt">>,
                                         <<"version">> => latest}]},
               Context))
      end).

memory_request_validation_test() ->
    Context = #{},
    ?assertEqual(
       {error, invalid_memory_search_request},
       adk_load_memory_tool:execute(#{}, Context)),
    ?assertEqual(
       {error, invalid_memory_search_request},
       adk_load_memory_tool:execute(#{<<"query">> => atom_query}, Context)),
    [?assertEqual(
        {error, invalid_memory_search_limit},
        adk_load_memory_tool:execute(
          #{<<"query">> => <<"query">>, <<"limit">> => Limit}, Context))
     || Limit <- [0, 21, 1.5, <<"5">>]].

memory_success_is_sanitized_test() ->
    Hits =
        [#{id => <<"atom-id">>, content => <<"atom content">>,
           score => 0.75, score_type => lexical_overlap, timestamp => 100,
           metadata => #{private => <<"secret">>}},
         #{<<"id">> => <<"binary-id">>,
           <<"content">> => <<"binary content">>,
           <<"score">> => 0.5,
           <<"score_type">> => <<"semantic">>,
           <<"timestamp">> => 200},
         #{id => <<"minimal-id">>, score_type => 42},
         not_a_map],
    with_fake_capability(
      [{ok, Hits}],
      fun(Context, Pid) ->
          ?assertEqual(
             {ok, #{<<"success">> => true,
                    <<"untrusted_reference_data">> => true,
                    <<"hits">> =>
                        [#{<<"id">> => <<"atom-id">>,
                           <<"content">> => <<"atom content">>,
                           <<"score">> => 0.75,
                           <<"score_type">> => <<"lexical_overlap">>,
                           <<"timestamp">> => 100},
                         #{<<"id">> => <<"binary-id">>,
                           <<"content">> => <<"binary content">>,
                           <<"score">> => 0.5,
                           <<"score_type">> => <<"semantic">>,
                           <<"timestamp">> => 200},
                         #{<<"id">> => <<"minimal-id">>},
                         #{}]}},
             adk_load_memory_tool:execute(
               #{<<"query">> => <<"what was remembered?">>}, Context)),
          ?assertEqual(
             [memory_request(Pid, <<"what was remembered?">>, 5)],
             receive_capability_requests(Pid, 1, []))
      end).

memory_error_and_invalid_reply_contract_test() ->
    with_fake_capability(
      [{error, memory_service_unavailable}],
      fun(Context, _Pid) ->
          ?assertEqual(
             {ok, #{<<"success">> => false,
                    <<"error">> => <<"memory_service_unavailable">>,
                    <<"hits">> => []}},
             adk_load_memory_tool:execute(
               #{<<"query">> => <<"query">>, <<"limit">> => 20}, Context))
      end),
    with_fake_capability(
      [{error, {backend, unavailable}}],
      fun(Context, _Pid) ->
          ?assertEqual(
             {ok, #{<<"success">> => false,
                    <<"error">> => <<"memory_operation_failed">>,
                    <<"hits">> => []}},
             adk_load_memory_tool:execute(
               #{<<"query">> => <<"query">>, <<"limit">> => 1}, Context))
      end),
    with_fake_capability(
      [unexpected_reply],
      fun(Context, _Pid) ->
          ?assertEqual(
             {error, {invalid_memory_service_reply, unexpected_reply}},
             adk_load_memory_tool:execute(
               #{<<"query">> => <<"query">>}, Context))
      end).

artifact_request(Pid, Name, Selector) ->
    {Pid, artifact_attach, #{name => Name, selector => Selector}}.

memory_request(Pid, Query, Limit) ->
    {Pid, memory_search,
     #{query => Query, options => #{filter => #{}, limit => Limit}}}.

with_fake_capability(Replies, Test) ->
    Parent = self(),
    Token = make_ref(),
    Pid = spawn(fun() -> capability_loop(Parent, Replies) end),
    Context = #{context_capability => {Pid, Token}, context_timeout => 1000},
    try Test(Context, Pid)
    after
        Pid ! stop
    end.

capability_loop(Parent, Replies) ->
    receive
        {'$gen_call', {Caller, Tag},
         {operation, _Token, Operation, Request}} ->
            Parent ! {capability_request, self(), Operation, Request},
            {Reply, Rest} = next_reply(Replies),
            Caller ! {Tag, Reply},
            capability_loop(Parent, Rest);
        stop ->
            ok
    end.

next_reply([Reply | Rest]) -> {Reply, Rest};
next_reply([]) -> {unexpected_extra_call, []}.

receive_capability_requests(_Pid, 0, Acc) ->
    lists:reverse(Acc);
receive_capability_requests(Pid, Count, Acc) ->
    receive
        {capability_request, Pid, Operation, Request} ->
            receive_capability_requests(
              Pid, Count - 1, [{Pid, Operation, Request} | Acc])
    after 1000 ->
        error({missing_capability_request, Count})
    end.
