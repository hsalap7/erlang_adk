%% @doc Recursive redaction for authentication data and diagnostic terms.
%%
%% Known secret-bearing keys and HTTP headers are always redacted. Explicit
%% seed values are also removed wherever they occur, including inside URLs.
-module(adk_secret_redactor).

-export([redact/1, redact/2, seed_values/1, marker/0]).

-define(REDACTED, <<"[REDACTED]">>).

-spec marker() -> binary().
marker() -> ?REDACTED.

-spec redact(term()) -> term().
redact(Term) ->
    redact(Term, []).

-spec redact(term(), [binary() | string()]) -> term().
redact(Term, Seeds0) ->
    Seeds = normalize_seeds(Seeds0),
    redact_term(Term, Seeds).

%% @doc Collect binary/string leaves from a credential for seeded error
%% redaction. The returned values must remain local to the refresh worker.
-spec seed_values(term()) -> [binary()].
seed_values(Term) ->
    lists:usort(seed_values(Term, [])).

redact_term(Map, Seeds) when is_map(Map) ->
    maps:from_list([
        {Key, case sensitive_key(Key) of
                  true -> ?REDACTED;
                  false -> redact_term(Value, Seeds)
              end}
        || {Key, Value} <- maps:to_list(Map)
    ]);
redact_term({Key, Value}, Seeds) when is_atom(Key) ->
    case sensitive_key(Key) of
        true -> {Key, ?REDACTED};
        false -> redact_tuple({Key, Value}, Seeds)
    end;
redact_term({Key, Value}, Seeds) when is_binary(Key); is_list(Key) ->
    case sensitive_key(Key) of
        true -> {Key, ?REDACTED};
        false -> redact_tuple({Key, Value}, Seeds)
    end;
redact_term(Tuple, Seeds) when is_tuple(Tuple) ->
    redact_tuple(Tuple, Seeds);
redact_term(Binary, Seeds) when is_binary(Binary) ->
    redact_binary(Binary, Seeds);
redact_term(List, Seeds) when is_list(List) ->
    case unicode_binary(List) of
        {ok, Binary} ->
            binary_to_list(redact_binary(Binary, Seeds));
        error ->
            redact_list(List, Seeds)
    end;
redact_term(Term, _Seeds) ->
    Term.

redact_tuple(Tuple, Seeds) ->
    list_to_tuple([redact_term(Value, Seeds) || Value <- tuple_to_list(Tuple)]).

redact_binary(Binary, Seeds) ->
    Seeded = lists:foldl(
               fun(Seed, Acc) ->
                   binary:replace(Acc, Seed, ?REDACTED, [global])
               end, Binary, Seeds),
    redact_url(Seeded, Seeds).

redact_url(Binary, Seeds) ->
    case binary:match(Binary, <<"://">>) of
        nomatch -> Binary;
        _ ->
            try uri_string:parse(Binary) of
                Uri when is_map(Uri) ->
                    Uri1 = case maps:is_key(userinfo, Uri) of
                        true -> Uri#{userinfo => ?REDACTED};
                        false -> Uri
                    end,
                    Uri2 = case maps:find(query, Uri1) of
                        {ok, Query} ->
                            Uri1#{query => redact_query(Query, Seeds)};
                        error -> Uri1
                    end,
                    unicode:characters_to_binary(uri_string:recompose(Uri2));
                _ -> Binary
            catch
                _:_ -> Binary
            end
    end.

redact_query(Query, Seeds) ->
    try uri_string:dissect_query(Query) of
        Pairs ->
            RedactedPairs = [
                case sensitive_key(Key) of
                    true -> {Key, ?REDACTED};
                    false -> {Key, redact_query_value(Value, Seeds)}
                end
                || {Key, Value} <- Pairs
            ],
            uri_string:compose_query(RedactedPairs)
    catch
        _:_ -> redact_binary_no_url(unicode:characters_to_binary(Query), Seeds)
    end.

redact_query_value(true, _Seeds) -> true;
redact_query_value(Value, Seeds) ->
    redact_binary_no_url(unicode:characters_to_binary(Value), Seeds).

redact_binary_no_url(Binary, Seeds) ->
    lists:foldl(
      fun(Seed, Acc) -> binary:replace(Acc, Seed, ?REDACTED, [global]) end,
      Binary, Seeds).

sensitive_key(Key) ->
    case normalized_key(Key) of
        undefined -> false;
        Normalized -> lists:member(Normalized, sensitive_keys())
    end.

sensitive_keys() ->
    [<<"authorization">>, <<"proxy_authorization">>, <<"x_api_key">>,
     <<"api_key">>, <<"apikey">>, <<"cookie">>, <<"set_cookie">>,
     <<"password">>, <<"passwd">>, <<"secret">>, <<"client_secret">>,
     <<"access_token">>, <<"refresh_token">>, <<"id_token">>,
     <<"token">>, <<"credential">>, <<"credentials">>,
     <<"private_key">>, <<"client_assertion">>, <<"bearer">>,
     <<"credential_rotator">>,
     <<"session_token">>, <<"security_token">>, <<"otp">>, <<"pin">>].

normalized_key(Key) when is_atom(Key) ->
    normalized_key(atom_to_binary(Key, utf8));
normalized_key(Key) when is_list(Key) ->
    try normalized_key(unicode:characters_to_binary(Key))
    catch _:_ -> undefined
    end;
normalized_key(Key) when is_binary(Key) ->
    Lower = string:lowercase(Key),
    binary:replace(Lower, <<"-">>, <<"_">>, [global]);
normalized_key(_) ->
    undefined.

normalize_seeds(Seeds) when is_list(Seeds) ->
    lists:usort(normalize_seed_list(Seeds, []));
normalize_seeds(_) ->
    [].

seed_to_binary(Seed) when is_binary(Seed) -> Seed;
seed_to_binary(Seed) when is_list(Seed) ->
    try unicode:characters_to_binary(Seed)
    catch _:_ -> undefined
    end;
seed_to_binary(_) -> undefined.

seed_values(Map, Acc) when is_map(Map) ->
    lists:foldl(
      fun({_Key, Value}, Values) ->
          seed_values(Value, Values)
      end, Acc, maps:to_list(Map));
seed_values(Tuple, Acc) when is_tuple(Tuple) ->
    lists:foldl(fun seed_values/2, Acc, tuple_to_list(Tuple));
seed_values(Binary, Acc) when is_binary(Binary), byte_size(Binary) > 0 ->
    [Binary | Acc];
seed_values(List, Acc) when is_list(List) ->
    case unicode_binary(List) of
        {ok, Binary} when byte_size(Binary) > 0 -> [Binary | Acc];
        {ok, _Empty} -> Acc;
        error -> seed_values_list(List, Acc)
    end;
seed_values(_Term, Acc) ->
    Acc.

unicode_binary([]) -> error;
unicode_binary(List) ->
    try unicode:characters_to_binary(List) of
        Binary when is_binary(Binary) -> {ok, Binary};
        _ -> error
    catch
        _:_ -> error
    end.

redact_list([], _Seeds) -> [];
redact_list([Head | Tail], Seeds) ->
    [redact_term(Head, Seeds) | redact_list_tail(Tail, Seeds)].

redact_list_tail([], _Seeds) -> [];
redact_list_tail([Head | Tail], Seeds) ->
    [redact_term(Head, Seeds) | redact_list_tail(Tail, Seeds)];
redact_list_tail(ImproperTail, Seeds) ->
    redact_term(ImproperTail, Seeds).

seed_values_list([], Acc) -> Acc;
seed_values_list([Head | Tail], Acc) ->
    seed_values_list_tail(Tail, seed_values(Head, Acc)).

seed_values_list_tail([], Acc) -> Acc;
seed_values_list_tail([Head | Tail], Acc) ->
    seed_values_list_tail(Tail, seed_values(Head, Acc));
seed_values_list_tail(ImproperTail, Acc) ->
    seed_values(ImproperTail, Acc).

normalize_seed_list([], Acc) -> Acc;
normalize_seed_list([Seed | Rest], Acc) ->
    Acc1 = case seed_to_binary(Seed) of
        Binary when is_binary(Binary), byte_size(Binary) > 0 -> [Binary | Acc];
        _ -> Acc
    end,
    normalize_seed_list(Rest, Acc1);
normalize_seed_list(_ImproperTail, Acc) -> Acc.
