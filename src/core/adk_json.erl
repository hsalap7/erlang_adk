%% @doc Safe conversion of ordinary Erlang values to a JSON value.
%%
%% This module is intentionally small and deterministic.  It is used at tool
%% and transport boundaries so internal terms such as pids, references, funs,
%% ports, and arbitrary printable crash data never leak into model prompts or
%% externally visible events.
-module(adk_json).

-export([normalize/1, normalize/2]).

-type path_part() :: binary() | non_neg_integer().
-type error_reason() ::
    {unsupported_json_term, [path_part()], atom()}
    | {invalid_utf8, [path_part()]}
    | {invalid_map_key, [path_part()], atom()}
    | {duplicate_map_key, [path_part()], binary()}.
-export_type([error_reason/0]).

-spec normalize(term()) -> {ok, term()} | {error, error_reason()}.
normalize(Value) ->
    normalize(Value, []).

-spec normalize(term(), [path_part()]) ->
    {ok, term()} | {error, error_reason()}.
normalize(Value, Path) when is_binary(Value) ->
    case valid_utf8(Value) of
        true -> {ok, Value};
        false -> {error, {invalid_utf8, Path}}
    end;
normalize(Value, _Path) when is_integer(Value); is_float(Value) ->
    {ok, Value};
normalize(true, _Path) -> {ok, true};
normalize(false, _Path) -> {ok, false};
normalize(null, _Path) -> {ok, null};
normalize(undefined, _Path) -> {ok, null};
normalize(Value, Path) when is_atom(Value) ->
    normalize(atom_to_binary(Value, utf8), Path);
normalize(Value, Path) when is_map(Value) ->
    normalize_map(maps:to_list(Value), Path, #{});
normalize([], _Path) ->
    {ok, []};
normalize(Value, Path) when is_list(Value) ->
    case printable_unicode(Value) of
        {ok, Text} -> {ok, Text};
        false -> normalize_list(Value, Path, 0, [])
    end;
normalize(Value, Path) when is_tuple(Value) ->
    normalize_list(tuple_to_list(Value), Path, 0, []);
normalize(Value, Path) ->
    {error, {unsupported_json_term, Path, term_type(Value)}}.

normalize_map([], _Path, Acc) ->
    {ok, Acc};
normalize_map([{RawKey, Value} | Rest], Path, Acc) ->
    case normalize_key(RawKey, Path) of
        {ok, Key} ->
            case maps:is_key(Key, Acc) of
                true -> {error, {duplicate_map_key, Path, Key}};
                false ->
                    case normalize(Value, Path ++ [Key]) of
                        {ok, JsonValue} ->
                            normalize_map(Rest, Path,
                                          Acc#{Key => JsonValue});
                        {error, _} = Error -> Error
                    end
            end;
        {error, _} = Error -> Error
    end.

normalize_key(Key, Path) when is_binary(Key) ->
    case valid_utf8(Key) of
        true -> {ok, Key};
        false -> {error, {invalid_utf8, Path}}
    end;
normalize_key(Key, _Path) when is_atom(Key) ->
    {ok, atom_to_binary(Key, utf8)};
normalize_key(Key, Path) when is_list(Key) ->
    case printable_unicode(Key) of
        {ok, Text} -> {ok, Text};
        false -> {error, {invalid_map_key, Path, term_type(Key)}}
    end;
normalize_key(Key, Path) ->
    {error, {invalid_map_key, Path, term_type(Key)}}.

normalize_list([], _Path, _Index, Acc) ->
    {ok, lists:reverse(Acc)};
normalize_list([Value | Rest], Path, Index, Acc) ->
    case normalize(Value, Path ++ [Index]) of
        {ok, JsonValue} ->
            normalize_list(Rest, Path, Index + 1,
                           [JsonValue | Acc]);
        {error, _} = Error -> Error
    end;
normalize_list(_ImproperTail, Path, Index, _Acc) ->
    {error, {unsupported_json_term, Path ++ [Index], improper_list}}.

printable_unicode(Value) ->
    try io_lib:printable_unicode_list(Value) of
        true ->
            case unicode:characters_to_binary(Value) of
                Text when is_binary(Text) -> {ok, Text};
                _ -> false
            end;
        false -> false
    catch
        _:_ -> false
    end.

valid_utf8(Value) ->
    case unicode:characters_to_binary(Value, utf8, utf8) of
        Value -> true;
        _ -> false
    end.

term_type(Value) when is_pid(Value) -> pid;
term_type(Value) when is_reference(Value) -> reference;
term_type(Value) when is_function(Value) -> function;
term_type(Value) when is_port(Value) -> port;
term_type(Value) when is_bitstring(Value) -> bitstring;
term_type(Value) when is_list(Value) -> improper_list;
term_type(_) -> other.

