-module(adk_llm_gemini).
-behaviour(adk_llm).

-export([generate/3, stream/4]).

-define(DEFAULT_MODEL, <<"gemini-3.1-flash-lite">>).

generate(Config, Memory, Tools) ->
    case get_api_key(Config) of
        {ok, ApiKey} ->
            generate_with_key(Config, Memory, Tools, ApiKey);
        {error, _} = Error ->
            Error
    end.

generate_with_key(Config, Memory, Tools, ApiKey) ->
    Model = maps:get(model, Config, ?DEFAULT_MODEL),
    BaseUrl = maps:get(base_url, Config, <<"https://generativelanguage.googleapis.com">>),
    Url = binary_to_list(BaseUrl) ++ "/v1beta/models/" ++
          binary_to_list(Model) ++ ":generateContent",
    JsonBody = jsx:encode(build_payload(Config, Memory, Tools)),
    Headers = [{"Content-Type", "application/json"},
               {"x-goog-api-key", binary_to_list(ApiKey)}],
    Request = {Url, Headers, "application/json", JsonBody},
    Options = [{body_format, binary}],

    case {ssl_options(BaseUrl), request_timeout(Config)} of
        {{ok, SslOptions}, {ok, RequestTimeout}} ->
            HttpOptions = add_request_timeout(
                            [{ssl, SslOptions}], RequestTimeout),
            case httpc:request(post, Request, HttpOptions, Options) of
                {ok, {{_Version, StatusCode, _ReasonPhrase}, _Headers, Body}}
                        when StatusCode >= 200, StatusCode < 300 ->
                    decode_response(Body);
                {ok, {{_Version, StatusCode, _ReasonPhrase}, _Headers, Body}} ->
                    {error, {http_status, StatusCode, Body}};
                {error, Reason} ->
                    {error, Reason}
            end;
        {{error, _} = Error, _} ->
            Error;
        {_, {error, _} = Error} ->
            Error
    end.

stream(Config, Memory, Tools, Callback) ->
    case get_api_key(Config) of
        {ok, ApiKey} ->
            stream_with_key(Config, Memory, Tools, Callback, ApiKey);
        {error, _} = Error ->
            Error
    end.

stream_with_key(Config, Memory, Tools, Callback, ApiKey) ->
    Model = maps:get(model, Config, ?DEFAULT_MODEL),
    BaseUrl = maps:get(base_url, Config, <<"https://generativelanguage.googleapis.com">>),
    case {stream_destination(BaseUrl, Model), request_timeout(Config)} of
        {{ok, Scheme, Host, Port, Path}, {ok, RequestTimeout}} ->
            case open_connection(Scheme, Host, Port) of
                {ok, ConnPid} ->
                    try
                        perform_stream_request(
                            ConnPid,
                            Path,
                            jsx:encode(build_payload(Config, Memory, Tools)),
                            Callback,
                            ApiKey,
                            gun_request_timeout(RequestTimeout)
                        )
                    catch
                        Class:Reason ->
                            {error, {stream_failed, Class, Reason}}
                    after
                        _ = catch gun:close(ConnPid)
                    end;
                {error, Reason} ->
                    {error, Reason}
            end;
        {{error, _} = Error, _} ->
            Error;
        {_, {error, _} = Error} ->
            Error
    end.

stream_destination(BaseUrl, Model) ->
    try uri_string:parse(BaseUrl) of
        #{host := Host, scheme := Scheme} = Uri
                when Scheme =:= <<"http">>; Scheme =:= <<"https">> ->
            BasePath = maps:get(path, Uri, <<>>),
            Port = case maps:get(port, Uri, undefined) of
                undefined when Scheme =:= <<"https">> -> 443;
                undefined -> 80;
                Value -> Value
            end,
            Path = binary_to_list(BasePath) ++ "/v1beta/models/" ++
                binary_to_list(Model) ++ ":streamGenerateContent?alt=sse",
            {ok, Scheme, Host, Port, Path};
        _ ->
            {error, invalid_base_url}
    catch
        _:_ -> {error, invalid_base_url}
    end.

%% Keep the transports' existing defaults when request_timeout is omitted:
%% httpc currently uses 60 seconds, while Gun awaits use 5 seconds. An
%% explicit value is useful when the caller has a tighter outer deadline.
request_timeout(Config) ->
    case maps:find(request_timeout, Config) of
        error ->
            {ok, default};
        {ok, infinity} ->
            {ok, infinity};
        {ok, Timeout} when is_integer(Timeout), Timeout >= 0 ->
            {ok, Timeout};
        {ok, Timeout} ->
            {error, {invalid_request_timeout, Timeout}}
    end.

add_request_timeout(HttpOptions, default) ->
    HttpOptions;
add_request_timeout(HttpOptions, RequestTimeout) ->
    [{timeout, RequestTimeout} | HttpOptions].

gun_request_timeout(default) -> 5000;
gun_request_timeout(RequestTimeout) -> RequestTimeout.

open_connection(<<"https">>, Host, Port) ->
    HostString = binary_to_list(Host),
    case tls_options(HostString) of
        {ok, TlsOptions} ->
            gun:open(HostString, Port,
                     #{transport => tls, tls_opts => TlsOptions});
        {error, _} = Error ->
            Error
    end;
open_connection(<<"http">>, Host, Port) ->
    gun:open(binary_to_list(Host), Port, #{transport => tcp}).

perform_stream_request(ConnPid, Path, JsonBody, Callback, ApiKey, RequestTimeout) ->
    case gun:await_up(ConnPid, RequestTimeout) of
        {ok, _Protocol} ->
            Headers = [{<<"content-type">>, <<"application/json">>},
                       {<<"x-goog-api-key">>, ApiKey}],
            StreamRef = gun:post(ConnPid, Path, Headers, JsonBody),
            await_stream_response(
              ConnPid, StreamRef, Callback, RequestTimeout);
        {error, Reason} ->
            {error, Reason}
    end.

await_stream_response(ConnPid, StreamRef, Callback, RequestTimeout) ->
    case gun:await(ConnPid, StreamRef, RequestTimeout) of
        {inform, _Status, _Headers} ->
            await_stream_response(
              ConnPid, StreamRef, Callback, RequestTimeout);
        {response, fin, Status, _Headers} when Status >= 200, Status < 300 ->
            ok;
        {response, fin, Status, _Headers} ->
            {error, {http_status, Status, <<>>}};
        {response, nofin, Status, _Headers} when Status >= 200, Status < 300 ->
            consume_stream_data(
              ConnPid, StreamRef, Callback, <<>>, [], RequestTimeout);
        {response, nofin, Status, _Headers} ->
            read_error_response(
              ConnPid, StreamRef, Status, RequestTimeout);
        {error, Reason} ->
            {error, Reason}
    end.

read_error_response(ConnPid, StreamRef, Status, RequestTimeout) ->
    case gun:await_body(ConnPid, StreamRef, RequestTimeout) of
        {ok, Body} -> {error, {http_status, Status, Body}};
        {ok, Body, _Trailers} -> {error, {http_status, Status, Body}};
        {error, Reason} -> {error, {http_status, Status, {body_error, Reason}}}
    end.

consume_stream_data(ConnPid, StreamRef, Callback, Buffer, ToolCallsAcc,
                    RequestTimeout) ->
    case gun:await(ConnPid, StreamRef, RequestTimeout) of
        {data, IsFin, Data} ->
            case consume_sse_bytes(<<Buffer/binary, Data/binary>>, Callback, ToolCallsAcc) of
                {ok, Rest, NewToolCallsAcc} when IsFin =:= nofin ->
                    consume_stream_data(
                      ConnPid, StreamRef, Callback, Rest, NewToolCallsAcc,
                      RequestTimeout);
                {ok, Rest, NewToolCallsAcc} ->
                    finish_sse(Rest, Callback, NewToolCallsAcc);
                {error, _} = Error ->
                    Error
            end;
        {trailers, _Trailers} ->
            finish_sse(Buffer, Callback, ToolCallsAcc);
        {error, Reason} ->
            {error, Reason}
    end.

consume_sse_bytes(Bytes, Callback, ToolCallsAcc) ->
    Normalized = binary:replace(Bytes, <<"\r\n">>, <<"\n">>, [global]),
    Parts = binary:split(Normalized, <<"\n\n">>, [global]),
    {Frames, [Rest]} = lists:split(length(Parts) - 1, Parts),
    case consume_sse_frames(Frames, Callback, ToolCallsAcc) of
        {ok, NewToolCallsAcc} -> {ok, Rest, NewToolCallsAcc};
        {error, _} = Error -> Error
    end.

consume_sse_frames([], _Callback, ToolCallsAcc) ->
    {ok, ToolCallsAcc};
consume_sse_frames([Frame | Rest], Callback, ToolCallsAcc) ->
    case consume_sse_frame(Frame, Callback) of
        {ok, ToolCalls} ->
            NewAcc = lists:reverse(ToolCalls, ToolCallsAcc),
            consume_sse_frames(Rest, Callback, NewAcc);
        done ->
            consume_sse_frames(Rest, Callback, ToolCallsAcc);
        {error, _} = Error ->
            Error
    end.

finish_sse(Buffer, Callback, ToolCallsAcc) ->
    case string:trim(Buffer) of
        <<>> -> final_stream_result(ToolCallsAcc);
        FinalFrame ->
            case consume_sse_frame(FinalFrame, Callback) of
                {ok, ToolCalls} ->
                    final_stream_result(lists:reverse(ToolCalls, ToolCallsAcc));
                done ->
                    final_stream_result(ToolCallsAcc);
                {error, _} = Error ->
                    Error
            end
    end.

final_stream_result([]) ->
    ok;
final_stream_result(ReversedToolCalls) ->
    {tool_calls, normalize_tool_call_signatures(lists:reverse(ReversedToolCalls))}.

consume_sse_frame(Frame, Callback) ->
    case sse_data(Frame) of
        none ->
            {ok, []};
        <<"[DONE]">> ->
            done;
        Data ->
            try jsx:decode(Data, [return_maps]) of
                Response -> consume_stream_response(Response, Callback)
            catch
                error:Reason -> {error, {invalid_sse_data, Reason, Data}}
            end
    end.

sse_data(Frame) ->
    Lines = binary:split(Frame, <<"\n">>, [global]),
    DataLines = lists:filtermap(
        fun
            (<<"data:", Rest/binary>>) -> {true, strip_optional_space(Rest)};
            (<<"data">>) -> {true, <<>>};
            (_) -> false
        end,
        Lines
    ),
    case DataLines of
        [] -> none;
        _ -> iolist_to_binary(lists:join(<<"\n">>, DataLines))
    end.

strip_optional_space(<<" ", Rest/binary>>) -> Rest;
strip_optional_space(Value) -> Value.

consume_stream_response(Response, Callback) ->
    Parts = response_parts(Response),
    TextDeltas = [Text || #{<<"text">> := Text} <- Parts, Text =/= <<>>],
    lists:foreach(Callback, TextDeltas),
    {ok, extract_tool_calls(Parts)}.

response_parts(#{<<"candidates">> := Candidates}) when is_list(Candidates) ->
    lists:append([
        Parts
        || #{<<"content">> := #{<<"parts">> := Parts}} <- Candidates,
           is_list(Parts)
    ]);
response_parts(_) ->
    [].

decode_response(Body) ->
    try jsx:decode(Body, [return_maps]) of
        ResponseMap -> parse_response(ResponseMap)
    catch
        error:Reason -> {error, {invalid_json, Reason}}
    end.

ssl_options(<<"http://", _/binary>>) ->
    {ok, []};
ssl_options(BaseUrl) ->
    case uri_string:parse(BaseUrl) of
        #{scheme := <<"https">>, host := Host} ->
            tls_options(binary_to_list(Host));
        _ ->
            {error, invalid_base_url}
    end.

tls_options(HostString) ->
    case ca_options() of
        {ok, CaOptions} ->
            %% OTP's default hostname matcher is deliberately strict and does
            %% not accept DNS wildcards. HTTPS certificates commonly use
            %% wildcard SANs (Google serves *.googleapis.com), so select the
            %% RFC-compatible HTTPS matcher explicitly for both httpc and gun.
            HostnameCheck = apply(public_key,
                                  pkix_verify_hostname_match_fun, [https]),
            {ok, [{server_name_indication, HostString},
                  {customize_hostname_check,
                   [{match_fun, HostnameCheck}]} | CaOptions]};
        {error, _} = Error ->
            Error
    end.

ca_options() ->
    %% Never silently downgrade certificate verification. If the host has no
    %% CA store, return a provider error rather than crashing or using
    %% verify_none.
    try apply(public_key, cacerts_get, []) of
        Certs -> {ok, [{verify, verify_peer}, {cacerts, Certs}]}
    catch
        Class:Reason -> {error, {ca_certificates_unavailable, Class, Reason}}
    end.

build_payload(Config, Memory, Tools) ->
    {SystemInstruction, Contents} = build_contents(Memory, <<>>, []),
    Payload0 = #{<<"contents">> => Contents},
    Payload1 = case SystemInstruction of
        <<>> -> Payload0;
        Sys -> Payload0#{
            <<"system_instruction">> => #{<<"parts">> => [#{<<"text">> => Sys}]}
        }
    end,
    GenConfig = build_gen_config(Config),
    Payload2 = case maps:size(GenConfig) of
        0 -> Payload1;
        _ -> Payload1#{<<"generationConfig">> => GenConfig}
    end,
    case Tools of
        [] -> Payload2;
        _ ->
            Declarations = [tool_schema(Tool) || Tool <- Tools],
            Payload2#{<<"tools">> => [#{<<"functionDeclarations">> => Declarations}]}
    end.

tool_schema(Schema) when is_map(Schema) -> Schema;
tool_schema(Module) when is_atom(Module) -> Module:schema().

get_api_key(Config) ->
    case maps:find(api_key, Config) of
        {ok, Key} ->
            {ok, to_binary(Key)};
        error ->
            case os:getenv("GEMINI_API_KEY") of
                false -> {error, missing_api_key};
                KeyStr -> {ok, list_to_binary(KeyStr)}
            end
    end.

build_contents([], SysAcc, ContentsAcc) ->
    {SysAcc, lists:reverse(ContentsAcc)};
build_contents([#{role := system, content := Content} | Rest], SysAcc, ContentsAcc) ->
    ContentBin = to_binary(Content),
    NewSys =
        case SysAcc of
            <<>> -> ContentBin;
            _ -> <<SysAcc/binary, "\n", ContentBin/binary>>
        end,
    build_contents(Rest, NewSys, ContentsAcc);
build_contents([#{role := tool} | _] = History, SysAcc, ContentsAcc) ->
    %% Group consecutive tool responses into a single 'user' message
    {ToolParts, Rest} = consume_tool_responses(History, []),
    Msg = #{<<"role">> => <<"user">>, <<"parts">> => ToolParts},
    build_contents(Rest, SysAcc, [Msg | ContentsAcc]);
build_contents([#{role := agent, content := {tool_calls, Calls}} | Rest], SysAcc, ContentsAcc) ->
    Parts = [begin
        {Name, Args, Sig, CallId} = case Call of
            {N, A} -> {N, A, undefined, undefined};
            {N, A, S} -> {N, A, S, undefined};
            {N, A, S, Id} -> {N, A, S, Id}
        end,
        FuncCall0 = #{
            <<"name">> => to_binary(Name),
            <<"args">> => Args
        },
        FuncCall = case CallId of
            undefined -> FuncCall0;
            _ -> FuncCall0#{<<"id">> => CallId}
        end,
        Part0 = #{<<"functionCall">> => FuncCall},
        case Sig of
            undefined -> Part0;
            _ -> Part0#{<<"thoughtSignature">> => Sig}
        end
    end || Call <- Calls],
    Msg = #{<<"role">> => <<"model">>, <<"parts">> => Parts},
    build_contents(Rest, SysAcc, [Msg | ContentsAcc]);
build_contents([#{role := Role, content := Content} | Rest], SysAcc, ContentsAcc) ->
    GeminiRole =
        case Role of
            user -> <<"user">>;
            agent -> <<"model">>
        end,
    Part = #{<<"text">> => to_binary(Content)},
    Msg = #{<<"role">> => GeminiRole, <<"parts">> => [Part]},
    build_contents(Rest, SysAcc, [Msg | ContentsAcc]).

consume_tool_responses([#{role := tool, content := {tool_response, Name, ResponseMap, Sig}} | Rest], Acc) ->
    FuncResp = #{
        <<"name">> => to_binary(Name),
        <<"response">> => ResponseMap
    },
    Part0 = #{<<"functionResponse">> => FuncResp},
    Part1 = case Sig of
        undefined -> Part0;
        _ -> Part0#{<<"thoughtSignature">> => Sig}
    end,
    consume_tool_responses(Rest, [Part1 | Acc]);
consume_tool_responses([#{role := tool, content := {tool_response, Name, ResponseMap, Sig, CallId}} | Rest], Acc) ->
    FuncResp = #{
        <<"id">> => CallId,
        <<"name">> => to_binary(Name),
        <<"response">> => ResponseMap
    },
    Part0 = #{<<"functionResponse">> => FuncResp},
    Part1 = case Sig of
        undefined -> Part0;
        _ -> Part0#{<<"thoughtSignature">> => Sig}
    end,
    consume_tool_responses(Rest, [Part1 | Acc]);
consume_tool_responses([#{role := tool, content := {tool_response, Name, ResponseMap}} | Rest], Acc) ->
    Part = #{<<"functionResponse">> => #{
        <<"name">> => to_binary(Name),
        <<"response">> => ResponseMap
    }},
    consume_tool_responses(Rest, [Part | Acc]);
consume_tool_responses(Rest, Acc) ->
    {lists:reverse(Acc), Rest}.

build_gen_config(Config) ->
    Keys = [
        {temperature, <<"temperature">>},
        {max_tokens, <<"maxOutputTokens">>},
        {top_p, <<"topP">>},
        {top_k, <<"topK">>}
    ],
    lists:foldl(
        fun({K, GeminiK}, Acc) ->
            case maps:find(K, Config) of
                {ok, V} -> Acc#{GeminiK => V};
                error -> Acc
            end
        end,
        #{},
        Keys
    ).

parse_response(#{<<"candidates">> := [#{<<"content">> := #{<<"parts">> := Parts}} | _]}) ->
    ToolCalls = normalize_tool_call_signatures(extract_tool_calls(Parts)),
    case ToolCalls of
        [] ->
            TextParts = [Text || #{<<"text">> := Text} <- Parts],
            case TextParts of
                [] -> {error, empty_response};
                _ -> {ok, iolist_to_binary(TextParts)}
            end;
        _ ->
            {tool_calls, ToolCalls}
    end;
parse_response(_) ->
    {error, invalid_response}.

extract_tool_calls(Parts) ->
    lists:filtermap(
        fun
            (Part = #{<<"functionCall">> := FuncCall}) ->
                Name = maps:get(<<"name">>, FuncCall),
                Args = maps:get(<<"args">>, FuncCall, #{}),
                Sig = maps:get(<<"thoughtSignature">>, Part, undefined),
                CallId = maps:get(<<"id">>, FuncCall, undefined),
                Call = case CallId of
                    undefined -> {Name, Args, Sig};
                    _ -> {Name, Args, Sig, CallId}
                end,
                {true, Call};
            (_) -> false
        end,
        Parts
    ).

%% Thought signatures belong to their original content parts. Keeping each
%% signature on its own call allows build_contents/3 to replay the model turn
%% exactly instead of copying one signature onto unrelated parallel calls.
normalize_tool_call_signatures(ToolCalls) ->
    ToolCalls.

to_binary(Atom) when is_atom(Atom) -> atom_to_binary(Atom, utf8);
to_binary(Str) when is_list(Str) -> unicode:characters_to_binary(Str);
to_binary(Bin) when is_binary(Bin) -> Bin.
