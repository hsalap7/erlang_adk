-module(adk_agent_yaml_edge_test).

-include_lib("eunit/include/eunit.hrl").

scalar_collection_and_comment_contract_test() ->
    Yaml =
        <<"empty_map: {}\r\n"
          "empty_list: []\n"
          "enabled: true\n"
          "disabled: false\n"
          "missing: null\n"
          "integer: -42\n"
          "decimal: 1.25\n"
          "exponent: 2e3\n"
          "upper_exponent: -2E-2\n"
          "double: \"hash # and colon: stay\" # comment\n"
          "single: 'it''s safe # text'\n"
          "plain_hash: value#fragment\n"
          "nested:\n"
          "  values:\n"
          "    - true\n"
          "    -\n"
          "    - name: first\n"
          "      count: 3\n">>,
    {ok, Parsed} = adk_agent_yaml:decode(Yaml),
    ?assertEqual(#{}, maps:get(<<"empty_map">>, Parsed)),
    ?assertEqual([], maps:get(<<"empty_list">>, Parsed)),
    ?assertEqual(true, maps:get(<<"enabled">>, Parsed)),
    ?assertEqual(false, maps:get(<<"disabled">>, Parsed)),
    ?assertEqual(null, maps:get(<<"missing">>, Parsed)),
    ?assertEqual(-42, maps:get(<<"integer">>, Parsed)),
    ?assertEqual(1.25, maps:get(<<"decimal">>, Parsed)),
    ?assertEqual(2000.0, maps:get(<<"exponent">>, Parsed)),
    ?assertEqual(-0.02, maps:get(<<"upper_exponent">>, Parsed)),
    ?assertEqual(<<"hash # and colon: stay">>,
                 maps:get(<<"double">>, Parsed)),
    ?assertEqual(<<"it's safe # text">>, maps:get(<<"single">>, Parsed)),
    ?assertEqual(<<"value#fragment">>, maps:get(<<"plain_hash">>, Parsed)),
    #{<<"values">> := [true, null,
                         #{<<"name">> := <<"first">>,
                           <<"count">> := 3}]} = maps:get(<<"nested">>, Parsed).

document_and_input_boundaries_fail_closed_test() ->
    ?assertEqual({error, {invalid_yaml, invalid_input, 1}},
                 adk_agent_yaml:decode(not_binary)),
    ?assertEqual({error, {invalid_yaml, empty_document, 1}},
                 adk_agent_yaml:decode(<<"# only a comment\n\n">>)),
    ?assertEqual({error, {invalid_yaml, invalid_utf8, 1}},
                 adk_agent_yaml:decode(<<16#ff>>)),
    ?assertEqual({error, {yaml_limit_exceeded, bytes}},
                 adk_agent_yaml:decode(binary:copy(<<"x">>, 1048577))),
    ?assertMatch({error, {invalid_yaml, invalid_character, _}},
                 adk_agent_yaml:decode(<<"name:\tbad\n">>)),
    ?assertMatch({error, {invalid_yaml, invalid_indentation, _}},
                 adk_agent_yaml:decode(<<"name:\n   child: bad\n">>)),
    ?assertEqual({error, {invalid_yaml,
                          root_must_start_at_column_zero, 1}},
                 adk_agent_yaml:decode(<<"  name: nested\n">>)),
    ?assertEqual({error, {invalid_yaml, trailing_document, 2}},
                 adk_agent_yaml:decode(<<"- first\nname: second\n">>)),
    ?assertEqual({error, {invalid_yaml, document_marker_not_allowed, 1}},
                 adk_agent_yaml:decode(<<"...\n">>)),
    ?assertEqual({error, {invalid_yaml, directive_not_allowed, 1}},
                 adk_agent_yaml:decode(<<"%YAML 1.2\n">>)),
    ?assertEqual({error, {invalid_yaml, unterminated_quote, 1}},
                 adk_agent_yaml:decode(<<"name: \"unfinished\n">>)).

mapping_and_sequence_structure_errors_test() ->
    Cases = [
        <<"plain-root\n">>,
        <<": value\n">>,
        <<"true: value\n">>,
        <<"parent:\n    child: too-deep\n">>,
        <<"items:\n  -\n      child: too-deep\n">>,
        <<"items:\n    - misplaced\n">>,
        <<"items:\n  - [one, two]\n">>,
        <<"items:\n  - {name: one}\n">>
    ],
    lists:foreach(
      fun(Yaml) -> ?assertMatch({error, _}, adk_agent_yaml:decode(Yaml)) end,
      Cases),
    ?assertEqual({ok, [null]}, adk_agent_yaml:decode(<<"-\n">>)),
    ?assertEqual({ok, [<<"one">>, <<"two">>]},
                 adk_agent_yaml:decode(<<"- one\n- two\n">>)).

quoted_and_plain_scalar_fail_closed_test() ->
    Invalid = [
        <<"value: \"closed\" trailing\n">>,
        <<"value: 'unterminated\n">>,
        <<"value: 'bad'quote'\n">>,
        <<"value: TRUE\n">>,
        <<"value: False\n">>,
        <<"value: Null\n">>,
        <<"value: |\n">>,
        <<"value: >\n">>,
        <<"value: ?tag\n">>,
        <<"value: @tag\n">>,
        <<"value: `tag\n">>,
        <<"value: ~\n">>,
        <<"value: prefix &anchor\n">>,
        <<"value: prefix *alias\n">>,
        <<"value: prefix !tag\n">>
    ],
    lists:foreach(
      fun(Yaml) -> ?assertMatch({error, _}, adk_agent_yaml:decode(Yaml)) end,
      Invalid),
    ?assertEqual({ok, #{<<"value">> => <<"line\nfeed">>}},
                 adk_agent_yaml:decode(<<"value: \"line\\nfeed\"\n">>)).

numeric_scalar_contract_test() ->
    Valid = [{<<"value: 0\n">>, 0},
             {<<"value: -1\n">>, -1},
             {<<"value: 0.5\n">>, 0.5},
             {<<"value: 1E2\n">>, 100.0}],
    lists:foreach(
      fun({Yaml, Expected}) ->
          ?assertEqual({ok, #{<<"value">> => Expected}},
                       adk_agent_yaml:decode(Yaml))
      end, Valid),
    ?assertEqual({ok, #{<<"value">> => <<"+1">>}},
                 adk_agent_yaml:decode(<<"value: +1\n">>)),
    Invalid = [<<"value: 01\n">>,
               <<"value: 1.\n">>, <<"value: .1\n">>,
               <<"value: 0x10\n">>, <<"value: -.inf\n">>,
               <<"value: ", (binary:copy(<<"9">>, 129))/binary, "\n">>],
    lists:foreach(
      fun(Yaml) ->
          ?assertMatch({error, {invalid_yaml, invalid_number, _}},
                       adk_agent_yaml:decode(Yaml))
      end, Invalid).

depth_and_line_limits_are_bounded_test() ->
    Deep = iolist_to_binary(
             [[binary:copy(<<" ">>, Depth * 2),
               <<"level_", (integer_to_binary(Depth))/binary, ":\n">>]
              || Depth <- lists:seq(0, 64)]),
    ?assertEqual({error, {yaml_limit_exceeded, depth}},
                 adk_agent_yaml:decode(Deep)),
    Lines = binary:copy(<<"x\n">>, 100001),
    ?assertEqual({error, {yaml_limit_exceeded, lines}},
                 adk_agent_yaml:decode(Lines)).
