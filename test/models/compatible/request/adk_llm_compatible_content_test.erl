-module(adk_llm_compatible_content_test).

-include_lib("eunit/include/eunit.hrl").

canonical_text_and_images_encode_with_binary_wire_keys_test() ->
    {ok, Text} = adk_content:text(<<"Describe">>),
    {ok, Inline} = adk_content:inline_data(
                     <<"image/png">>, <<0, 1, 2>>),
    {ok, Remote} = adk_content:file_data(
                     <<"image/jpeg">>,
                     <<"https://images.example.test/photo.jpg">>),
    {ok, Content} = adk_content:new([Text, Inline, Remote]),
    {ok, [Message]} = adk_llm_compatible_content:encode(
                        user, Content, #{}),
    ?assertEqual(<<"user">>, maps:get(<<"role">>, Message)),
    [TextWire, InlineWire, RemoteWire] = maps:get(<<"content">>, Message),
    ?assertEqual(<<"text">>, maps:get(<<"type">>, TextWire)),
    InlineUrl = maps:get(
                  <<"url">>, maps:get(<<"image_url">>, InlineWire)),
    ?assertMatch(<<"data:image/png;base64,", _/binary>>, InlineUrl),
    ?assertEqual(<<"https://images.example.test/photo.jpg">>,
                 maps:get(<<"url">>,
                          maps:get(<<"image_url">>, RemoteWire))),
    assert_binary_json_keys(Message).

assistant_and_tool_history_preserve_call_correlation_test() ->
    {ok, Text} = adk_content:text(<<"Checking weather">>),
    {ok, Call} = adk_content:function_call(
                   <<"weather">>, #{<<"city">> => <<"Paris">>},
                   #{id => <<"call-1">>}),
    {ok, Assistant} = adk_content:new([Text, Call]),
    {ok, Response} = adk_content:function_response(
                       <<"weather">>,
                       #{<<"temperature_c">> => 18},
                       #{id => <<"call-1">>}),
    {ok, ToolContent} = adk_content:new([Response]),
    History = [#{role => system, content => <<"Be concise">>},
               #{role => user, content => <<"Weather?">>},
               #{role => agent, content => Assistant},
               #{role => tool, content => ToolContent}],
    {ok, [System, User, AssistantWire, ToolWire]} =
        adk_llm_compatible_content:encode_history(History, #{}),
    ?assertEqual(<<"system">>, maps:get(<<"role">>, System)),
    ?assertEqual(<<"user">>, maps:get(<<"role">>, User)),
    ?assertEqual(<<"Checking weather">>,
                 maps:get(<<"content">>, AssistantWire)),
    [WireCall] = maps:get(<<"tool_calls">>, AssistantWire),
    ?assertEqual(<<"call-1">>, maps:get(<<"id">>, WireCall)),
    ?assertEqual(<<"tool">>, maps:get(<<"role">>, ToolWire)),
    ?assertEqual(<<"call-1">>, maps:get(<<"tool_call_id">>, ToolWire)),
    ?assertEqual(#{<<"temperature_c">> => 18},
                 jsx:decode(maps:get(<<"content">>, ToolWire),
                            [return_maps])),
    lists:foreach(fun assert_binary_json_keys/1,
                  [System, User, AssistantWire, ToolWire]).

json_schema_tools_are_nested_and_bounded_test() ->
    Tool = tool_schema(<<"weather">>),
    {ok, [Encoded]} = adk_llm_compatible_content:encode_tools([Tool]),
    ?assertEqual(<<"function">>, maps:get(<<"type">>, Encoded)),
    Function = maps:get(<<"function">>, Encoded),
    ?assertEqual(<<"weather">>, maps:get(<<"name">>, Function)),
    ?assertEqual(true, maps:get(<<"strict">>, Function)),
    ?assertMatch(#{<<"type">> := <<"object">>},
                 maps:get(<<"parameters">>, Function)),
    assert_binary_json_keys(Encoded),
    ?assertEqual(
       {error, {duplicate_compatible_tool, 1}},
       adk_llm_compatible_content:encode_tools([Tool, Tool])).

one_shot_message_decodes_parallel_calls_test() ->
    Message = #{<<"role">> => <<"assistant">>,
                <<"content">> => <<"I will check both">>,
                <<"tool_calls">> =>
                    [wire_call(<<"call-a">>, <<"weather">>,
                               #{<<"city">> => <<"Paris">>}),
                     wire_call(<<"call-b">>, <<"time">>,
                               #{<<"zone">> => <<"UTC">>})]},
    {ok, Content, Calls} =
        adk_llm_compatible_content:decode_message(Message, #{}),
    ?assertEqual(2, length(Calls)),
    ?assertEqual(
       [{<<"weather">>, #{<<"city">> => <<"Paris">>},
         undefined, <<"call-a">>},
        {<<"time">>, #{<<"zone">> => <<"UTC">>},
         undefined, <<"call-b">>}], Calls),
    ?assertEqual({tool_calls, Calls},
                 adk_llm_compatible_content:outcome(Content)).

unsupported_media_and_invalid_remote_arguments_are_sanitized_test() ->
    {ok, Audio} = adk_content:inline_data(<<"audio/wav">>, <<1, 2>>),
    {ok, AudioContent} = adk_content:new([Audio]),
    ?assertEqual(
       {error, unsupported_compatible_inline_media},
       adk_llm_compatible_content:encode(user, AudioContent, #{})),
    Secret = <<"remote-argument-secret-must-not-leak">>,
    Message = #{<<"role">> => <<"assistant">>,
                <<"content">> => null,
                <<"tool_calls">> =>
                    [#{<<"id">> => <<"call-a">>,
                       <<"type">> => <<"function">>,
                       <<"function">> =>
                           #{<<"name">> => <<"weather">>,
                             <<"arguments">> => Secret}}]},
    Error = adk_llm_compatible_content:decode_message(Message, #{}),
    ?assertMatch({error, {invalid_compatible_tool_call, 0,
                          invalid_arguments}}, Error),
    ?assertEqual(nomatch, binary:match(term_to_binary(Error), Secret)).

remote_strings_never_become_atoms_test() ->
    Name = <<"role_that_must_not_become_an_atom_819273645">>,
    ?assertError(badarg, binary_to_existing_atom(Name, utf8)),
    ?assertEqual(
       {error, invalid_compatible_assistant_message},
       adk_llm_compatible_content:decode_message(
         #{<<"role">> => Name, <<"content">> => <<"x">>}, #{})),
    ?assertError(badarg, binary_to_existing_atom(Name, utf8)).

tool_schema(Name) ->
    #{<<"name">> => Name,
      <<"description">> => <<"Get data">>,
      <<"strict">> => true,
      <<"parameters">> =>
          #{<<"type">> => <<"object">>,
            <<"properties">> =>
                #{<<"city">> => #{<<"type">> => <<"string">>}},
            <<"required">> => [<<"city">>]}}.

wire_call(Id, Name, Args) ->
    #{<<"id">> => Id,
      <<"type">> => <<"function">>,
      <<"function">> =>
          #{<<"name">> => Name,
            <<"arguments">> => jsx:encode(Args)}}.

assert_binary_json_keys(Map) when is_map(Map) ->
    ?assert(lists:all(fun is_binary/1, maps:keys(Map))),
    lists:foreach(fun({_Key, Value}) -> assert_binary_json_keys(Value) end,
                  maps:to_list(Map));
assert_binary_json_keys([Head | Tail]) ->
    assert_binary_json_keys(Head),
    assert_binary_json_keys(Tail);
assert_binary_json_keys([]) -> ok;
assert_binary_json_keys(_Value) -> ok.
