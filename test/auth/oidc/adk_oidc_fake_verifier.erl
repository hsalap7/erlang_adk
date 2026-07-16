-module(adk_oidc_fake_verifier).

-behaviour(adk_jwt_verifier).

-export([verify/2]).

verify(Token, #{adapter_options := Options}) ->
    notify(Options, {jwt_verifier_started, self()}),
    case maps:get(mode, Options, normal) of
        throw -> erlang:error({fixture_verifier_failure, Token,
                               maps:get(secret, Options, undefined)});
        crash -> exit({fixture_verifier_crash,
                       maps:get(secret, Options, undefined)});
        sleep ->
            timer:sleep(maps:get(delay_ms, Options, 1000)),
            decode_token(Token);
        heap -> exhaust_heap([]);
        oversized ->
            {ok, #{<<"padding">> => binary:copy(<<"x">>, 262144)}};
        normal -> decode_token(Token)
    end;
verify(Token, _Config) ->
    decode_token(Token).

decode_token(Token) ->
    case binary:split(Token, <<".">>, [global]) of
        [_Header, Payload, _Signature] ->
            case decode_base64url(Payload) of
                {ok, Json} ->
                    try jsx:decode(Json, [return_maps]) of
                        Claims when is_map(Claims) -> {ok, Claims};
                        _ -> {error, invalid_token}
                    catch
                        _:_ -> {error, invalid_token}
                    end;
                error -> {error, invalid_token}
            end;
        _ -> {error, invalid_token}
    end.

notify(Options, Message) ->
    case maps:get(observer, Options, undefined) of
        Observer when is_pid(Observer) -> Observer ! Message;
        _ -> ok
    end.

exhaust_heap(Acc) ->
    exhaust_heap([make_ref(), make_ref(), make_ref(), make_ref() | Acc]).

decode_base64url(Segment) ->
    Standard0 = binary:replace(Segment, <<"-">>, <<"+">>, [global]),
    Standard = binary:replace(Standard0, <<"_">>, <<"/">>, [global]),
    PaddingLength = (4 - (byte_size(Standard) rem 4)) rem 4,
    Padding = case PaddingLength of
        0 -> <<>>;
        1 -> <<"=">>;
        2 -> <<"==">>;
        3 -> <<"===">>
    end,
    try base64:decode(<<Standard/binary, Padding/binary>>) of
        Decoded -> {ok, Decoded}
    catch
        _:_ -> error
    end.
