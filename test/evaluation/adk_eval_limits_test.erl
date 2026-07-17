-module(adk_eval_limits_test).

-include_lib("eunit/include/eunit.hrl").

defaults_are_finite_and_accept_ordinary_data_test() ->
    Defaults = adk_eval_limits:defaults(),
    ?assertEqual(
       [max_binary_bytes, max_depth, max_external_bytes,
        max_list_length, max_map_size, max_nodes,
        max_total_binary_bytes],
       lists:sort(maps:keys(Defaults))),
    ?assert(lists:all(
              fun(Value) -> is_integer(Value) andalso Value > 0 end,
              maps:values(Defaults))),
    ?assertEqual(
       ok,
       adk_eval_limits:check(
         #{<<"binary">> => [one, {two, 3}], flag => true})).

invalid_limit_overrides_are_rejected_test() ->
    ?assertEqual({error, invalid_eval_limits},
                 adk_eval_limits:check(value, invalid)),
    ?assertEqual({error, invalid_eval_limits},
                 adk_eval_limits:check(value, #{max_nodes => 0})),
    ?assertEqual({error, invalid_eval_limits},
                 adk_eval_limits:check(value,
                                       #{max_depth => infinity})).

external_term_budget_is_checked_first_test() ->
    Value = #{payload => <<0:256>>},
    Size = erlang:external_size(Value),
    ?assertEqual(
       {error, {eval_data_too_large, Size, Size - 1}},
       adk_eval_limits:check(Value, #{max_external_bytes => Size - 1})).

depth_and_node_budgets_are_enforced_test() ->
    Deep = [[[[value]]]],
    ?assertEqual(
       {error, {eval_data_depth_exceeded, 2}},
       adk_eval_limits:check(
         Deep, generous(#{max_depth => 2}))),
    ?assertEqual(
       {error, {eval_data_nodes_exceeded, 2}},
       adk_eval_limits:check(
         [first, second], generous(#{max_nodes => 2}))).

per_binary_and_total_binary_budgets_are_distinct_test() ->
    ?assertEqual(
       {error, {eval_binary_too_large, 4, 3}},
       adk_eval_limits:check(
         <<"four">>,
         generous(#{max_binary_bytes => 3}))),
    ?assertEqual(
       {error, {eval_binary_budget_exceeded, 3}},
       adk_eval_limits:check(
         [<<"aa">>, <<"bb">>],
         generous(#{max_binary_bytes => 2,
                    max_total_binary_bytes => 3}))),
    ?assertEqual(
       {error, {eval_binary_too_large, 4, 3}},
       adk_eval_limits:check(
         #{<<"four">> => ok},
         generous(#{max_binary_bytes => 3}))),
    ?assertEqual(
       {error, {eval_binary_too_large, 4, 3}},
       adk_eval_limits:check(
         #{key => <<"four">>},
         generous(#{max_binary_bytes => 3}))).

collection_budgets_and_improper_lists_are_checked_test() ->
    ?assertEqual(
       {error, {eval_map_too_large, 2, 1}},
       adk_eval_limits:check(
         #{one => 1, two => 2},
         generous(#{max_map_size => 1}))),
    ?assertEqual(
       {error, {eval_list_too_large, 1}},
       adk_eval_limits:check(
         [one, two], generous(#{max_list_length => 1}))),
    ?assertEqual(
       ok,
       adk_eval_limits:check(
         {tuple, [proper], [improper | tail]}, generous(#{}))).

generous(Overrides) ->
    maps:merge(
      #{max_depth => 100,
        max_nodes => 1000,
        max_binary_bytes => 1000,
        max_total_binary_bytes => 1000,
        max_list_length => 100,
        max_map_size => 100,
        max_external_bytes => 100000},
      Overrides).
