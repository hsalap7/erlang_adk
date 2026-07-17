%% @doc Cowboy boundary for the MCP 2025-11-25 Streamable HTTP transport.
-module(adk_mcp_http_handler).

-export([init/2]).

-define(JSON, <<"application/json">>).
-define(MAX_CALLBACK_RESULT_BYTES, 4096).

init(Req0, Config) ->
    case authorize_request(Req0, Config) of
        {ok, AuthContext} -> dispatch(Req0, Config, AuthContext);
        {error, origin_forbidden} -> reply_empty(403, Req0, Config);
        {error, Reason} -> reply_auth_error(Reason, Req0, Config)
    end.

dispatch(Req0, Config, AuthContext) ->
    case cowboy_req:method(Req0) of
        <<"POST">> -> handle_post(Req0, Config, AuthContext);
        <<"GET">> ->
            %% This bounded implementation does not expose an unsolicited SSE
            %% channel. MCP explicitly permits a 405 response for GET.
            reply_empty(405, Req0, Config);
        <<"DELETE">> -> handle_delete(Req0, Config, AuthContext);
        _ -> reply_empty(405, Req0, Config)
    end.

handle_post(Req0, Config, AuthContext) ->
    case {accepts_mcp_response(Req0), json_content_type(Req0)} of
        {false, _} -> reply_empty(406, Req0, Config);
        {true, false} -> reply_empty(415, Req0, Config);
        {true, true} ->
            Max = maps:get(max_body_bytes, Config),
            case read_body(Req0, Max, [], 0) of
                {ok, Body, Req1} ->
                    decode_and_dispatch(Body, Req1, Config, AuthContext);
                {error, too_large, Req1} -> reply_empty(413, Req1, Config)
            end
    end.

decode_and_dispatch(Body, Req0, Config, AuthContext) ->
    case decode_message(Body) of
        {ok, Message} ->
            case authorize_operation(Message, AuthContext, Config) of
                ok ->
                    dispatch_message(Message, Req0, Config, AuthContext);
                {error, Reason} ->
                    reply_auth_error(Reason, Req0, Config)
            end;
        error ->
            Error = jsonrpc_error(null, -32700, <<"Parse error">>),
            reply_json(400, Error, Req0, Config)
    end.

dispatch_message(Message, Req0, Config, AuthContext) ->
    Session = cowboy_req:header(<<"mcp-session-id">>, Req0),
    Version = cowboy_req:header(<<"mcp-protocol-version">>, Req0),
    Server = maps:get(server, Config),
    Timeout = maps:get(request_timeout, Config),
    case safe_server_call(Server, Session, Version, Message,
                          AuthContext, Timeout) of
                {json, Status, Headers, Response} ->
                    BodyOut = jsx:encode(Response),
                    Req1 = cowboy_req:reply(
                             Status,
                             maps:from_list(
                               [{<<"content-type">>, ?JSON} | Headers]),
                             BodyOut, Req0),
                    {ok, Req1, Config};
                {accepted, Headers} ->
                    Req1 = cowboy_req:reply(202, maps:from_list(Headers),
                                            <<>>, Req0),
                    {ok, Req1, Config};
                {http_error, Status, Headers} ->
                    Req1 = cowboy_req:reply(Status, maps:from_list(Headers),
                                            <<>>, Req0),
                    {ok, Req1, Config}
    end.

authorize_operation(Message, AuthContext,
                    #{authorization := {hook, Fun}} = Config) ->
    {Operation, Resource} = operation_summary(Message),
    invoke_callback(authorization, Fun,
                    [AuthContext, Operation, Resource], Config);
authorize_operation(_Message, _AuthContext, _Config) -> ok.

operation_summary(#{<<"method">> := Method} = Message)
  when is_binary(Method), byte_size(Method) > 0,
       byte_size(Method) =< 256 ->
    Params = maps:get(<<"params">>, Message, #{}),
    {Method, operation_resource(Method, Params)};
operation_summary(_Message) -> {<<"invalid">>, #{kind => protocol}}.

operation_resource(<<"tools/call">>, Params) ->
    named_resource(tool, <<"name">>, Params);
operation_resource(<<"prompts/get">>, Params) ->
    named_resource(prompt, <<"name">>, Params);
operation_resource(<<"resources/read">>, Params) ->
    named_resource(resource, <<"uri">>, Params);
operation_resource(<<"tools/list">>, _Params) -> #{kind => tools};
operation_resource(<<"prompts/list">>, _Params) -> #{kind => prompts};
operation_resource(<<"resources/list">>, _Params) -> #{kind => resources};
operation_resource(<<"initialize">>, _Params) -> #{kind => session};
operation_resource(_Method, _Params) -> #{kind => protocol}.

named_resource(Kind, Key, Params) when is_map(Params) ->
    case maps:get(Key, Params, undefined) of
        Value when is_binary(Value), byte_size(Value) > 0,
                                     byte_size(Value) =< 2048 ->
            #{kind => Kind, id => Value};
        _ -> #{kind => Kind}
    end;
named_resource(Kind, _Key, _Params) -> #{kind => Kind}.

decode_message(Body) ->
    try jsx:decode(Body, [return_maps]) of
        Message when is_map(Message) -> {ok, Message};
        _ -> error
    catch _:_ -> error
    end.

safe_server_call(Server, Session, Version, Message, AuthContext, Timeout) ->
    try adk_mcp_server:handle_http(Server, Session, Version,
                                   Message, AuthContext, Timeout) of
        Reply -> Reply
    catch
        exit:{timeout, _} -> {http_error, 504, []};
        exit:_ -> {http_error, 503, []}
    end.

handle_delete(Req0, Config, AuthContext) ->
    Session = cowboy_req:header(<<"mcp-session-id">>, Req0),
    Version = cowboy_req:header(<<"mcp-protocol-version">>, Req0),
    Server = maps:get(server, Config),
    case authorize_delete(AuthContext, Config) of
        {error, Reason} -> reply_auth_error(Reason, Req0, Config);
        ok -> delete_authorized(Server, Session, Version, AuthContext,
                                Req0, Config)
    end.

authorize_delete(AuthContext, #{authorization := {hook, Fun}} = Config) ->
    invoke_callback(authorization, Fun,
                    [AuthContext, <<"sessions/delete">>,
                     #{kind => session}], Config);
authorize_delete(_AuthContext, _Config) -> ok.

delete_authorized(Server, Session, Version, AuthContext, Req0, Config) ->
    case adk_mcp_server:delete_session(Server, Session, Version,
                                       AuthContext) of
        ok -> reply_empty(204, Req0, Config);
        {error, missing_session} -> reply_empty(400, Req0, Config);
        {error, invalid_protocol_version} -> reply_empty(400, Req0, Config);
        {error, unknown_session} -> reply_empty(404, Req0, Config)
    end.

authorize_request(Req, Config) ->
    case valid_origin(Req, Config) of
        false -> {error, origin_forbidden};
        true -> authorize_header(cowboy_req:header(<<"authorization">>, Req),
                                 Req, Config)
    end.

authorize_header(_Header, _Req, #{auth := none}) ->
    auth_context(<<"anonymous">>);
authorize_header(Header, _Req, #{auth := {bearer_sha256, Expected}}) ->
    case bearer_candidate(Header) of
        {ok, Candidate} ->
            Digest = crypto:hash(sha256, Candidate),
            case adk_dev_auth:constant_time_equal(Digest, Expected) of
                true -> auth_context(<<"static-bearer">>);
                false -> {error, unauthenticated}
            end;
        error -> {error, unauthenticated}
    end;
authorize_header(Header, Req, #{auth := {hook, Fun}} = Config) ->
    Meta = #{authorization => Header,
             method => cowboy_req:method(Req),
             endpoint => maps:get(path, Config),
             origin => cowboy_req:header(<<"origin">>, Req),
             peer => cowboy_req:peer(Req)},
    invoke_callback(authentication, Fun, [Meta], Config).

%% Execute untrusted application callbacks through the shared authentication
%% boundary.  It normalizes and bounds the result in a monitored, heap-limited
%% worker, rejects completion after the absolute deadline, suppresses late
%% alias replies, and reaps the callback if this Cowboy request process exits.
invoke_callback(Kind, Fun, Args, Config) ->
    Timeout = maps:get(callback_timeout, Config),
    MaxHeap = maps:get(callback_max_heap_words, Config),
    Callback = fun() -> erlang:apply(Fun, Args) end,
    Normalizer = fun(Value) -> normalize_callback_result(Kind, Value) end,
    case adk_auth_callback_guard:run(
           Callback, Normalizer, Timeout, MaxHeap,
           ?MAX_CALLBACK_RESULT_BYTES) of
        {ok, Result} -> Result;
        timeout -> callback_failure(Kind);
        failed -> callback_failure(Kind)
    end.

normalize_callback_result(authentication, ok) ->
    auth_context(<<"legacy-hook">>);
normalize_callback_result(authentication, true) ->
    auth_context(<<"legacy-hook">>);
normalize_callback_result(authentication, {ok, PrincipalId}) ->
    auth_context(PrincipalId);
normalize_callback_result(authentication, {error, unauthenticated}) ->
    {error, unauthenticated};
normalize_callback_result(authentication, {error, forbidden}) ->
    {error, forbidden};
normalize_callback_result(authentication, {error, insufficient_scope}) ->
    {error, insufficient_scope};
normalize_callback_result(authentication, _Invalid) ->
    {error, unauthenticated};
normalize_callback_result(authorization, ok) -> ok;
normalize_callback_result(authorization, true) -> ok;
normalize_callback_result(authorization, {error, insufficient_scope}) ->
    {error, insufficient_scope};
normalize_callback_result(authorization, {error, forbidden}) ->
    {error, forbidden};
normalize_callback_result(authorization, _Invalid) ->
    {error, forbidden}.

callback_failure(authentication) -> {error, unauthenticated};
callback_failure(authorization) -> {error, forbidden}.

auth_context(PrincipalId)
  when is_binary(PrincipalId), byte_size(PrincipalId) > 0,
       byte_size(PrincipalId) =< 512 ->
    {ok, #{principal_id => PrincipalId,
           scope => crypto:hash(sha256, PrincipalId)}};
auth_context(_) -> {error, unauthenticated}.

bearer_candidate(undefined) -> error;
bearer_candidate(Header) when is_binary(Header) ->
    case binary:split(Header, <<" ">>) of
        [Scheme, Candidate] when byte_size(Candidate) > 0 ->
            case {lower(Scheme), valid_token(Candidate)} of
                {<<"bearer">>, true} -> {ok, Candidate};
                _ -> error
            end;
        _ -> error
    end.

valid_token(Value) ->
    lists:all(fun(C) -> C > 16#20 andalso C =/= 16#7f end,
              binary_to_list(Value)).

valid_origin(Req, Config) ->
    case cowboy_req:header(<<"origin">>, Req) of
        undefined -> true;
        Origin -> lists:member(lower(Origin), maps:get(allowed_origins,
                                                       Config, []))
    end.

accepts_mcp_response(Req) ->
    case cowboy_req:header(<<"accept">>, Req) of
        undefined -> false;
        Accept ->
            Lower = lower(Accept),
            binary:match(Lower, <<"application/json">>) =/= nomatch andalso
            binary:match(Lower, <<"text/event-stream">>) =/= nomatch
    end.

json_content_type(Req) ->
    case cowboy_req:header(<<"content-type">>, Req) of
        undefined -> false;
        Value ->
            lower(hd(binary:split(Value, <<";">>))) =:= ?JSON
    end.

read_body(Req0, Max, Acc, Size) ->
    Length = cowboy_req:header(<<"content-length">>, Req0),
    case content_length_within(Length, Max) of
        false -> {error, too_large, Req0};
        true ->
            case cowboy_req:read_body(
                   Req0, #{length => erlang:min(Max + 1, 65536),
                           period => 5000}) of
                {ok, Data, Req1} ->
                    finish_body(Data, Req1, Max, Acc, Size);
                {more, Data, Req1} ->
                    NewSize = Size + byte_size(Data),
                    case NewSize =< Max of
                        true -> read_body(Req1, Max, [Data | Acc], NewSize);
                        false -> {error, too_large, Req1}
                    end
            end
    end.

finish_body(Data, Req, Max, Acc, Size) ->
    case Size + byte_size(Data) =< Max of
        true -> {ok, iolist_to_binary(lists:reverse([Data | Acc])), Req};
        false -> {error, too_large, Req}
    end.

content_length_within(undefined, _Max) -> true;
content_length_within(Value, Max) ->
    try binary_to_integer(Value) of
        Length -> Length >= 0 andalso Length =< Max
    catch _:_ -> false
    end.

reply_empty(Status, Req0, Config) ->
    Req1 = cowboy_req:reply(Status, #{}, <<>>, Req0),
    {ok, Req1, Config}.

reply_auth_error(Reason, Req0, Config) ->
    Status = case Reason of
        unauthenticated -> 401;
        _ -> 403
    end,
    Challenge = bearer_challenge(Reason, Config),
    Req1 = cowboy_req:reply(
             Status, #{<<"www-authenticate">> => Challenge}, <<>>, Req0),
    {ok, Req1, Config}.

bearer_challenge(Reason, Config) ->
    case maps:get(oauth_protected_resource, Config, none) of
        #{resource_metadata_url := MetadataUrl,
          required_scopes := RequiredScopes} ->
            Parts0 = [<<"Bearer resource_metadata=\"", MetadataUrl/binary,
                        "\"">>],
            Parts1 = case Reason of
                insufficient_scope ->
                    Parts0 ++ [<<"error=\"insufficient_scope\"">>];
                _ -> Parts0
            end,
            Parts = case RequiredScopes of
                [] -> Parts1;
                _ -> Parts1 ++
                     [<<"scope=\"",
                        (join_scopes(RequiredScopes))/binary, "\"">>]
            end,
            iolist_to_binary(lists:join(<<", ">>, Parts));
        none ->
            case Reason of
                insufficient_scope ->
                    <<"Bearer error=\"insufficient_scope\"">>;
                _ -> <<"Bearer">>
            end
    end.

join_scopes(Scopes) ->
    iolist_to_binary(lists:join(<<" ">>, Scopes)).

reply_json(Status, Message, Req0, Config) ->
    Req1 = cowboy_req:reply(Status,
                            #{<<"content-type">> => ?JSON},
                            jsx:encode(Message), Req0),
    {ok, Req1, Config}.

jsonrpc_error(Id, Code, Message) ->
    #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => Id,
      <<"error">> => #{<<"code">> => Code,
                        <<"message">> => Message}}.

lower(Value) ->
    list_to_binary(string:lowercase(binary_to_list(Value))).
