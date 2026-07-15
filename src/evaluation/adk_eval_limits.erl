%% @doc Resource limits for persisted evaluation data.
%%
%% The evaluator accepts ordinary Erlang terms for convenience, but persisted
%% sets, results, baselines, and reports are untrusted data boundaries.  This
%% walker rejects structures which would otherwise make recursive JSON
%% normalization consume an unbounded caller heap or stack.
-module(adk_eval_limits).

-export([check/1, check/2, defaults/0]).

-define(DEFAULT_MAX_DEPTH, 64).
-define(DEFAULT_MAX_NODES, 100000).
-define(DEFAULT_MAX_BINARY_BYTES, 1048576).
-define(DEFAULT_MAX_TOTAL_BINARY_BYTES, 8388608).
-define(DEFAULT_MAX_LIST_LENGTH, 10000).
-define(DEFAULT_MAX_MAP_SIZE, 10000).
-define(DEFAULT_MAX_EXTERNAL_BYTES, 16777216).

-spec defaults() -> map().
defaults() ->
    #{max_depth => ?DEFAULT_MAX_DEPTH,
      max_nodes => ?DEFAULT_MAX_NODES,
      max_binary_bytes => ?DEFAULT_MAX_BINARY_BYTES,
      max_total_binary_bytes => ?DEFAULT_MAX_TOTAL_BINARY_BYTES,
      max_list_length => ?DEFAULT_MAX_LIST_LENGTH,
      max_map_size => ?DEFAULT_MAX_MAP_SIZE,
      max_external_bytes => ?DEFAULT_MAX_EXTERNAL_BYTES}.

-spec check(term()) -> ok | {error, term()}.
check(Value) ->
    check(Value, #{}).

-spec check(term(), map()) -> ok | {error, term()}.
check(Value, Overrides) when is_map(Overrides) ->
    Limits = maps:merge(defaults(), Overrides),
    case valid_limits(Limits) of
        true ->
            try erlang:external_size(Value) of
                Size ->
                    case Size =< maps:get(max_external_bytes, Limits) of
                        true ->
                            case walk(Value, 0, 0, 0, Limits) of
                                {ok, _Nodes, _Bytes} -> ok;
                                {error, _} = Error -> Error
                            end;
                        false ->
                            {error, {eval_data_too_large, Size,
                                     maps:get(max_external_bytes, Limits)}}
                    end
            catch
                error:system_limit -> {error, eval_data_system_limit};
                _:_ -> {error, invalid_eval_data}
            end;
        false ->
            {error, invalid_eval_limits}
    end;
check(_Value, _Overrides) ->
    {error, invalid_eval_limits}.

walk(Value, Depth, Nodes, Bytes, Limits) ->
    case {Depth > maps:get(max_depth, Limits),
          Nodes >= maps:get(max_nodes, Limits)} of
        {true, _} ->
            {error, {eval_data_depth_exceeded,
                     maps:get(max_depth, Limits)}};
        {_, true} ->
            {error, {eval_data_nodes_exceeded,
                     maps:get(max_nodes, Limits)}};
        {false, false} ->
            walk_value(Value, Depth, Nodes, Bytes, Limits)
    end.

walk_value(Value, _Depth, Nodes, Bytes, Limits) when is_binary(Value) ->
    Size = byte_size(Value),
    case {Size =< maps:get(max_binary_bytes, Limits),
          Bytes + Size =< maps:get(max_total_binary_bytes, Limits)} of
        {true, true} -> {ok, Nodes + 1, Bytes + Size};
        {false, _} ->
            {error, {eval_binary_too_large, Size,
                     maps:get(max_binary_bytes, Limits)}};
        {_, false} ->
            {error, {eval_binary_budget_exceeded,
                     maps:get(max_total_binary_bytes, Limits)}}
    end;
walk_value(Value, Depth, Nodes, Bytes, Limits) when is_map(Value) ->
    Size = map_size(Value),
    case Size =< maps:get(max_map_size, Limits) of
        true -> walk_pairs(maps:to_list(Value), Depth + 1,
                           Nodes + 1, Bytes, Limits);
        false ->
            {error, {eval_map_too_large, Size,
                     maps:get(max_map_size, Limits)}}
    end;
walk_value(Value, Depth, Nodes, Bytes, Limits) when is_tuple(Value) ->
    walk_list(tuple_to_list(Value), Depth + 1, Nodes + 1, Bytes,
              Limits, 0);
walk_value(Value, Depth, Nodes, Bytes, Limits) when is_list(Value) ->
    walk_list(Value, Depth + 1, Nodes + 1, Bytes, Limits, 0);
walk_value(_Value, _Depth, Nodes, Bytes, _Limits) ->
    {ok, Nodes + 1, Bytes}.

walk_pairs([], _Depth, Nodes, Bytes, _Limits) ->
    {ok, Nodes, Bytes};
walk_pairs([{Key, Value} | Rest], Depth, Nodes0, Bytes0, Limits) ->
    case walk(Key, Depth, Nodes0, Bytes0, Limits) of
        {ok, Nodes1, Bytes1} ->
            case walk(Value, Depth, Nodes1, Bytes1, Limits) of
                {ok, Nodes2, Bytes2} ->
                    walk_pairs(Rest, Depth, Nodes2, Bytes2, Limits);
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end.

walk_list([], _Depth, Nodes, Bytes, _Limits, _Length) ->
    {ok, Nodes, Bytes};
walk_list([Head | Tail], Depth, Nodes0, Bytes0, Limits, Length) ->
    case Length < maps:get(max_list_length, Limits) of
        true ->
            case walk(Head, Depth, Nodes0, Bytes0, Limits) of
                {ok, Nodes1, Bytes1} ->
                    walk_list(Tail, Depth, Nodes1, Bytes1, Limits,
                              Length + 1);
                {error, _} = Error -> Error
            end;
        false ->
            {error, {eval_list_too_large,
                     maps:get(max_list_length, Limits)}}
    end;
walk_list(Improper, Depth, Nodes, Bytes, Limits, _Length) ->
    walk(Improper, Depth, Nodes, Bytes, Limits).

valid_limits(Limits) ->
    lists:all(
      fun(Key) ->
          Value = maps:get(Key, Limits, invalid),
          is_integer(Value) andalso Value > 0
      end,
      [max_depth, max_nodes, max_binary_bytes, max_total_binary_bytes,
       max_list_length, max_map_size, max_external_bytes]).
