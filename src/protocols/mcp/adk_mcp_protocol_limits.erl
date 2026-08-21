%% @doc Strict, bounded JSON validation for MCP protocol foundations.
%%
%% This boundary accepts JSON values only: UTF-8 binary strings and keys,
%% finite numbers, booleans, null, proper lists, and maps.  It deliberately
%% does not normalize atoms, tuples, pids, references, or functions because
%% doing so at a wire boundary can turn internal terms into protocol data.
-module(adk_mcp_protocol_limits).

-export([defaults/0, validate_json/1, validate_json/2, encoded_bytes/1,
         encoded_bytes/2]).

-define(DEFAULT_MAX_BYTES, 1048576).
-define(DEFAULT_MAX_DEPTH, 32).
-define(DEFAULT_MAX_NODES, 20000).
-define(DEFAULT_MAX_BINARY_BYTES, 262144).
-define(DEFAULT_MAX_TOTAL_BINARY_BYTES, 1048576).
-define(DEFAULT_MAX_LIST_LENGTH, 4096).
-define(DEFAULT_MAX_MAP_SIZE, 1024).
-define(DEFAULT_MAX_EXTERNAL_BYTES, 4194304).

-spec defaults() -> map().
defaults() ->
    #{max_bytes => ?DEFAULT_MAX_BYTES,
      max_depth => ?DEFAULT_MAX_DEPTH,
      max_nodes => ?DEFAULT_MAX_NODES,
      max_binary_bytes => ?DEFAULT_MAX_BINARY_BYTES,
      max_total_binary_bytes => ?DEFAULT_MAX_TOTAL_BINARY_BYTES,
      max_list_length => ?DEFAULT_MAX_LIST_LENGTH,
      max_map_size => ?DEFAULT_MAX_MAP_SIZE,
      max_external_bytes => ?DEFAULT_MAX_EXTERNAL_BYTES}.

-spec validate_json(term()) -> {ok, term()} | {error, term()}.
validate_json(Value) ->
    validate_json(Value, #{}).

-spec validate_json(term(), map()) -> {ok, term()} | {error, term()}.
validate_json(Value, Overrides) when is_map(Overrides) ->
    case limits(Overrides) of
        {ok, Limits} -> validate_with_limits(Value, Limits);
        {error, _} = Error -> Error
    end;
validate_json(_Value, _Overrides) ->
    {error, invalid_mcp_json_limits}.

-spec encoded_bytes(term()) -> {ok, non_neg_integer()} | {error, term()}.
encoded_bytes(Value) ->
    encoded_bytes(Value, #{}).

-spec encoded_bytes(term(), map()) ->
    {ok, non_neg_integer()} | {error, term()}.
encoded_bytes(Value, Overrides) when is_map(Overrides) ->
    case validate_json(Value, Overrides) of
        {ok, Safe} ->
            try jsx:encode(Safe) of
                Encoded when is_binary(Encoded) -> {ok, byte_size(Encoded)}
            catch
                _:_ -> {error, invalid_mcp_json}
            end;
        {error, _} = Error -> Error
    end;
encoded_bytes(_Value, _Overrides) ->
    {error, invalid_mcp_json_limits}.

validate_with_limits(Value, Limits) ->
    try erlang:external_size(Value) of
        ExternalBytes when ExternalBytes =<
                           map_get(max_external_bytes, Limits) ->
            case walk(Value, 0, 0, 0, Limits) of
                {ok, _Nodes, _BinaryBytes} -> encoded_limit(Value, Limits);
                {error, _} = Error -> Error
            end;
        _ExternalBytes -> {error, mcp_json_external_size_exceeded}
    catch
        error:system_limit -> {error, mcp_json_system_limit};
        _:_ -> {error, invalid_mcp_json}
    end.

encoded_limit(Value, Limits) ->
    try jsx:encode(Value) of
        Encoded when is_binary(Encoded) ->
            case byte_size(Encoded) =< maps:get(max_bytes, Limits) of
                true -> {ok, Value};
                false -> {error, mcp_json_encoded_size_exceeded}
            end
    catch
        _:_ -> {error, invalid_mcp_json}
    end.

walk(_Value, Depth, _Nodes, _Bytes, Limits)
  when Depth > map_get(max_depth, Limits) ->
    {error, mcp_json_depth_exceeded};
walk(_Value, _Depth, Nodes, _Bytes, Limits)
  when Nodes >= map_get(max_nodes, Limits) ->
    {error, mcp_json_node_count_exceeded};
walk(Value, _Depth, Nodes, Bytes, Limits) when is_binary(Value) ->
    Size = byte_size(Value),
    case valid_utf8(Value) of
        false -> {error, invalid_mcp_json_utf8};
        true when Size > map_get(max_binary_bytes, Limits) ->
            {error, mcp_json_binary_size_exceeded};
        true when Bytes + Size > map_get(max_total_binary_bytes, Limits) ->
            {error, mcp_json_binary_budget_exceeded};
        true -> {ok, Nodes + 1, Bytes + Size}
    end;
walk(Value, _Depth, Nodes, Bytes, _Limits) when is_integer(Value) ->
    {ok, Nodes + 1, Bytes};
walk(Value, _Depth, Nodes, Bytes, _Limits) when is_float(Value) ->
    try float_to_binary(Value, [short]) of
        <<"nan">> -> {error, invalid_mcp_json_number};
        <<"inf">> -> {error, invalid_mcp_json_number};
        <<"-inf">> -> {error, invalid_mcp_json_number};
        _Finite -> {ok, Nodes + 1, Bytes}
    catch
        _:_ -> {error, invalid_mcp_json_number}
    end;
walk(true, _Depth, Nodes, Bytes, _Limits) ->
    {ok, Nodes + 1, Bytes};
walk(false, _Depth, Nodes, Bytes, _Limits) ->
    {ok, Nodes + 1, Bytes};
walk(null, _Depth, Nodes, Bytes, _Limits) ->
    {ok, Nodes + 1, Bytes};
walk(Value, Depth, Nodes, Bytes, Limits) when is_list(Value) ->
    walk_list(Value, Depth + 1, Nodes + 1, Bytes, Limits, 0);
walk(Value, Depth, Nodes, Bytes, Limits) when is_map(Value) ->
    case map_size(Value) =< maps:get(max_map_size, Limits) of
        true -> walk_pairs(maps:to_list(Value), Depth + 1,
                           Nodes + 1, Bytes, Limits);
        false -> {error, mcp_json_map_size_exceeded}
    end;
walk(_Value, _Depth, _Nodes, _Bytes, _Limits) ->
    {error, invalid_mcp_json_type}.

walk_list([], _Depth, Nodes, Bytes, _Limits, _Length) ->
    {ok, Nodes, Bytes};
walk_list([Head | Tail], Depth, Nodes0, Bytes0, Limits, Length)
  when Length < map_get(max_list_length, Limits) ->
    case walk(Head, Depth, Nodes0, Bytes0, Limits) of
        {ok, Nodes1, Bytes1} ->
            walk_list(Tail, Depth, Nodes1, Bytes1, Limits, Length + 1);
        {error, _} = Error -> Error
    end;
walk_list([_Head | _Tail], _Depth, _Nodes, _Bytes, _Limits, _Length) ->
    {error, mcp_json_list_length_exceeded};
walk_list(_Improper, _Depth, _Nodes, _Bytes, _Limits, _Length) ->
    {error, invalid_mcp_json_list}.

walk_pairs([], _Depth, Nodes, Bytes, _Limits) ->
    {ok, Nodes, Bytes};
walk_pairs([{Key, Value} | Rest], Depth, Nodes0, Bytes0, Limits) ->
    case is_binary(Key) andalso valid_utf8(Key) of
        false -> {error, invalid_mcp_json_key};
        true ->
            case walk(Key, Depth, Nodes0, Bytes0, Limits) of
                {ok, Nodes1, Bytes1} ->
                    case walk(Value, Depth, Nodes1, Bytes1, Limits) of
                        {ok, Nodes2, Bytes2} ->
                            walk_pairs(Rest, Depth, Nodes2, Bytes2, Limits);
                        {error, _} = Error -> Error
                    end;
                {error, _} = Error -> Error
            end
    end.

limits(Overrides) ->
    Allowed = maps:keys(defaults()),
    case maps:keys(maps:without(Allowed, Overrides)) of
        [] ->
            Limits = maps:merge(defaults(), Overrides),
            case valid_limits(Limits) of
                true -> {ok, Limits};
                false -> {error, invalid_mcp_json_limits}
            end;
        _Unknown -> {error, invalid_mcp_json_limits}
    end.

valid_limits(Limits) ->
    lists:all(
      fun(Key) ->
          Value = maps:get(Key, Limits, invalid),
          is_integer(Value) andalso Value > 0
      end, maps:keys(defaults())).

valid_utf8(Value) ->
    try unicode:characters_to_binary(Value, utf8, utf8) of
        Value -> true;
        _ -> false
    catch
        _:_ -> false
    end.
