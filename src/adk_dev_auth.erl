%% @doc Bearer authentication and same-origin checks for local developer APIs.
-module(adk_dev_auth).

-export([authorize/2, same_origin/1, constant_time_equal/2]).

-spec authorize(cowboy_req:req(), map()) ->
    ok | {error, unauthorized | forbidden | unavailable}.
authorize(Req, Config) ->
    case maps:get(auth_token_digest, Config, undefined) of
        Digest when is_binary(Digest), byte_size(Digest) =:= 32 ->
            authorize_header(cowboy_req:header(<<"authorization">>, Req),
                             Digest);
        _ ->
            {error, unavailable}
    end.

authorize_header(undefined, _Expected) ->
    {error, unauthorized};
authorize_header(Header, ExpectedDigest) when is_binary(Header) ->
    %% binary:split/2 splits only on the first occurrence.  Any remaining
    %% whitespace stays in Candidate and is rejected by valid_candidate/1.
    case binary:split(Header, <<" ">>) of
        [Scheme, Candidate] when byte_size(Candidate) > 0 ->
            case lowercase_ascii(Scheme) of
                <<"bearer">> ->
                    case valid_candidate(Candidate) andalso
                         constant_time_digest(
                           crypto:hash(sha256, Candidate),
                           ExpectedDigest) of
                        true -> ok;
                        false -> {error, forbidden}
                    end;
                _ ->
                    {error, unauthorized}
            end;
        _ ->
            {error, unauthorized}
    end.

valid_candidate(Candidate) ->
    binary:match(Candidate, <<" ">>) =:= nomatch andalso
    binary:match(Candidate, <<"\t">>) =:= nomatch andalso
    binary:match(Candidate, <<"\r">>) =:= nomatch andalso
    binary:match(Candidate, <<"\n">>) =:= nomatch.

%% @doc Compare arbitrary binaries through fixed-size SHA-256 digests.
-spec constant_time_equal(binary(), binary()) -> boolean().
constant_time_equal(Left, Right) when is_binary(Left), is_binary(Right) ->
    LeftDigest = crypto:hash(sha256, Left),
    RightDigest = crypto:hash(sha256, Right),
    constant_time_digest(LeftDigest, RightDigest);
constant_time_equal(_, _) ->
    false.

constant_time_digest(LeftDigest, RightDigest)
  when byte_size(LeftDigest) =:= 32, byte_size(RightDigest) =:= 32 ->
    constant_time_bytes(LeftDigest, RightDigest, 0) =:= 0.

constant_time_bytes(<<>>, <<>>, Difference) ->
    Difference;
constant_time_bytes(<<Left, LeftRest/binary>>,
                    <<Right, RightRest/binary>>, Difference) ->
    constant_time_bytes(LeftRest, RightRest,
                        Difference bor (Left bxor Right)).

%% Requests without Origin remain available to local CLI clients. Browsers
%% which send Origin must match the listener's own scheme and Host header.
-spec same_origin(cowboy_req:req()) -> boolean().
same_origin(Req) ->
    case cowboy_req:header(<<"origin">>, Req) of
        undefined -> true;
        Origin ->
            Scheme = cowboy_req:scheme(Req),
            HostHeader = cowboy_req:header(<<"host">>, Req),
            case is_binary(Scheme) andalso is_binary(HostHeader) of
                true ->
                    Expected = <<Scheme/binary, "://", HostHeader/binary>>,
                    lowercase_ascii(Origin) =:= lowercase_ascii(Expected);
                false ->
                    false
            end
    end.

lowercase_ascii(Value) ->
    << <<(lower_ascii(Char))>> || <<Char>> <= Value >>.

lower_ascii(Char) when Char >= $A, Char =< $Z -> Char + 32;
lower_ascii(Char) -> Char.
