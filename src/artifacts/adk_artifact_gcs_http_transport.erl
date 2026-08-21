%% @doc Hardened Google Cloud Storage JSON API transport.
%%
%% The endpoint, HTTPS scheme, host allow-list, redirect policy and headers
%% are fixed here. Callers supply only a validated bucket/project, opaque
%% credential handle, object name and bounded payload. There is deliberately
%% no endpoint, URL or arbitrary-header option.
-module(adk_artifact_gcs_http_transport).
-behaviour(adk_artifact_gcs_transport).

-export([put_if_absent/4, get/3, get_range/5, list/5, delete/3]).

-define(ORIGIN, <<"https://storage.googleapis.com">>).
-define(HOST, <<"storage.googleapis.com">>).
-define(MAX_LIST_BODY_BYTES, 4 * 1024 * 1024).
-define(MAX_CURSOR_BYTES, 4096).

-spec put_if_absent(term(), binary(), binary(),
                    adk_artifact_gcs_transport:context()) ->
    ok | {error, term()}.
put_if_absent(Handle, Object, Data, Context)
  when is_binary(Object), is_binary(Data), is_map(Context) ->
    Query = <<"uploadType=media&name=", (encode(Object))/binary,
              "&ifGenerationMatch=0&userProject=",
              (encode(maps:get(project, Context)))/binary>>,
    Path = <<"/upload/storage/v1/b/",
             (encode(maps:get(bucket, Context)))/binary,
             "/o?", Query/binary>>,
    case request(Handle, <<"POST">>, Path,
                 [{<<"content-type">>, <<"application/octet-stream">>}],
                 Data, Context, 65536) of
        {ok, #{status := Status}} when Status =:= 200; Status =:= 201 -> ok;
        {ok, #{status := 412}} -> {error, exists};
        {ok, #{status := Status}} -> status_error(Status);
        {error, _} = Error -> Error
    end;
put_if_absent(_Handle, _Object, _Data, _Context) ->
    {error, invalid_request}.

-spec get(term(), binary(), adk_artifact_gcs_transport:context()) ->
    {ok, binary()} | {error, term()}.
get(Handle, Object, Context) when is_binary(Object), is_map(Context) ->
    Path = media_path(Object, Context),
    Limit = maps:get(max_response_bytes, Context),
    case request(Handle, <<"GET">>, Path, [], <<>>, Context, Limit) of
        {ok, #{status := 200, body := Body}} -> {ok, Body};
        {ok, #{status := 404}} -> {error, not_found};
        {ok, #{status := Status}} -> status_error(Status);
        {error, _} = Error -> Error
    end;
get(_Handle, _Object, _Context) ->
    {error, invalid_request}.

-spec get_range(term(), binary(), non_neg_integer(), pos_integer(),
                adk_artifact_gcs_transport:context()) ->
    {ok, binary()} | {error, term()}.
get_range(Handle, Object, Offset, Length, Context)
  when is_binary(Object), is_integer(Offset), Offset >= 0,
       is_integer(Length), Length > 0, is_map(Context) ->
    End = Offset + Length - 1,
    Range = <<"bytes=", (integer_to_binary(Offset))/binary, "-",
              (integer_to_binary(End))/binary>>,
    Path = media_path(Object, Context),
    RangeContext = Context#{max_response_bytes => Length},
    case request(Handle, <<"GET">>, Path, [{<<"range">>, Range}], <<>>,
                 RangeContext, Length) of
        {ok, #{status := 206, body := Body}} when byte_size(Body) =:= Length ->
            {ok, Body};
        {ok, #{status := 404}} -> {error, not_found};
        {ok, #{status := 416}} -> {error, invalid_range};
        {ok, #{status := 206}} -> {error, invalid_response};
        {ok, #{status := Status}} -> status_error(Status);
        {error, _} = Error -> Error
    end;
get_range(_Handle, _Object, _Offset, _Length, _Context) ->
    {error, invalid_request}.

-spec list(term(), binary(), binary() | undefined, pos_integer(),
           adk_artifact_gcs_transport:context()) ->
    {ok, adk_artifact_gcs_transport:page()} | {error, term()}.
list(Handle, Prefix, Cursor, Limit, Context)
  when is_binary(Prefix), is_integer(Limit), Limit > 0, is_map(Context) ->
    case valid_cursor(Cursor) of
        false -> {error, invalid_cursor};
        true ->
            BaseQuery = <<"prefix=", (encode(Prefix))/binary,
                          "&maxResults=", (integer_to_binary(Limit))/binary,
                          "&userProject=",
                          (encode(maps:get(project, Context)))/binary>>,
            Query = case Cursor of
                undefined -> BaseQuery;
                _ -> <<BaseQuery/binary, "&pageToken=",
                       (encode(Cursor))/binary>>
            end,
            Path = <<"/storage/v1/b/",
                     (encode(maps:get(bucket, Context)))/binary,
                     "/o?", Query/binary>>,
            BodyLimit = erlang:min(?MAX_LIST_BODY_BYTES,
                                   maps:get(max_response_bytes, Context)),
            case request(Handle, <<"GET">>, Path, [], <<>>, Context,
                         BodyLimit) of
                {ok, #{status := 200, body := Body}} -> decode_page(Body);
                {ok, #{status := Status}} -> status_error(Status);
                {error, _} = Error -> Error
            end
    end;
list(_Handle, _Prefix, _Cursor, _Limit, _Context) ->
    {error, invalid_request}.

-spec delete(term(), binary(), adk_artifact_gcs_transport:context()) ->
    ok | {error, term()}.
delete(Handle, Object, Context) when is_binary(Object), is_map(Context) ->
    Path = object_path(Object, Context),
    case request(Handle, <<"DELETE">>, Path, [], <<>>, Context, 65536) of
        {ok, #{status := Status}} when Status =:= 200; Status =:= 204 -> ok;
        {ok, #{status := 404}} -> {error, not_found};
        {ok, #{status := Status}} -> status_error(Status);
        {error, _} = Error -> Error
    end;
delete(_Handle, _Object, _Context) ->
    {error, invalid_request}.

request(Handle, Method, Path, ExtraHeaders, Body, Context, ResponseLimit) ->
    Deadline = maps:get(deadline, Context),
    case adk_artifact_gcs_credential:resolve(
           maps:get(credential, Context), Deadline) of
        {ok, Token} ->
            Authorization = <<"Bearer ", Token/binary>>,
            Request = #{method => Method,
                        url => <<?ORIGIN/binary, Path/binary>>,
                        headers => [{<<"authorization">>, Authorization}
                                    | ExtraHeaders],
                        body => Body,
                        timeout_ms => erlang:max(1, remaining(Deadline)),
                        max_response_bytes => ResponseLimit,
                        follow_redirects => false,
                        allowed_schemes => [<<"https">>],
                        allowed_hosts => [?HOST],
                        allow_private_hosts => false},
            invoke_http(Handle, Request);
        {error, timeout} -> {error, timeout};
        {error, _} -> {error, credential_unavailable}
    end.

invoke_http(undefined, Request) ->
    invoke_http({adk_openapi_gun_transport, undefined}, Request);
invoke_http({Module, HttpHandle}, Request) when is_atom(Module) ->
    try Module:request(HttpHandle, Request) of
        {ok, #{status := Status, body := Body} = Response}
          when is_integer(Status), Status >= 100, Status =< 599,
               is_binary(Body) -> {ok, Response};
        {error, timeout} -> {error, timeout};
        {error, response_too_large} -> {error, response_too_large};
        {error, _} -> {error, transport_failed};
        _ -> {error, invalid_response}
    catch
        _:_ -> {error, transport_failed}
    end;
invoke_http(_Handle, _Request) ->
    {error, invalid_transport_handle}.

media_path(Object, Context) ->
    Base = object_path(Object, Context),
    <<Base/binary, "&alt=media">>.

object_path(Object, Context) ->
    <<"/storage/v1/b/", (encode(maps:get(bucket, Context)))/binary,
      "/o/", (encode(Object))/binary,
      "?userProject=", (encode(maps:get(project, Context)))/binary>>.

decode_page(Body) when is_binary(Body) ->
    try jsx:decode(Body, [return_maps]) of
        Decoded when is_map(Decoded) ->
            Items0 = maps:get(<<"items">>, Decoded, []),
            Cursor = maps:get(<<"nextPageToken">>, Decoded, undefined),
            case {decode_names(Items0, []), valid_cursor(Cursor)} of
                {{ok, Names}, true} ->
                    {ok, #{items => lists:reverse(Names),
                           next_cursor => Cursor}};
                _ -> {error, invalid_response}
            end;
        _ -> {error, invalid_response}
    catch
        _:_ -> {error, invalid_response}
    end.

decode_names([], Acc) -> {ok, Acc};
decode_names([#{<<"name">> := Name} | Rest], Acc)
  when is_binary(Name), byte_size(Name) > 0 ->
    decode_names(Rest, [Name | Acc]);
decode_names(_Items, _Acc) -> error.

valid_cursor(undefined) -> true;
valid_cursor(Cursor)
  when is_binary(Cursor), byte_size(Cursor) > 0,
       byte_size(Cursor) =< ?MAX_CURSOR_BYTES ->
    not has_control(Cursor);
valid_cursor(_Cursor) -> false.

status_error(401) -> {error, credential_unavailable};
status_error(403) -> {error, forbidden};
status_error(408) -> {error, timeout};
status_error(429) -> {error, overloaded};
status_error(Status) when Status >= 500 -> {error, unavailable};
status_error(_Status) -> {error, storage_request_failed}.

encode(Binary) when is_binary(Binary) ->
    iolist_to_binary([encode_byte(Byte) || <<Byte>> <= Binary]).

encode_byte(Byte)
  when (Byte >= $a andalso Byte =< $z) orelse
       (Byte >= $A andalso Byte =< $Z) orelse
       (Byte >= $0 andalso Byte =< $9) orelse
       Byte =:= $- orelse Byte =:= $_ orelse Byte =:= $. orelse
       Byte =:= $~ -> <<Byte>>;
encode_byte(Byte) ->
    Digits = <<"0123456789ABCDEF">>,
    <<"%", (binary:at(Digits, Byte bsr 4)),
      (binary:at(Digits, Byte band 16#0f))>>.

has_control(Binary) ->
    lists:any(fun(Byte) -> Byte < 32 orelse Byte =:= 127 end,
              binary_to_list(Binary)).

remaining(Deadline) ->
    erlang:max(0, Deadline - erlang:monotonic_time(millisecond)).
