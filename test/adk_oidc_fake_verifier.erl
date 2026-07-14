-module(adk_oidc_fake_verifier).

-behaviour(adk_jwt_verifier).

-export([verify/2]).

verify(Token, #{adapter_options := #{mode := throw,
                                     secret := Secret}}) ->
    erlang:error({fixture_verifier_failure, Token, Secret});
verify(Token, _Config) ->
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
