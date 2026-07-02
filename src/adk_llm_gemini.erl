-module(adk_llm_gemini).
-behaviour(adk_llm).

-export([generate/3]).

generate(Config, Memory, Tools) ->
    %% Default to gemini-1.5-flash if model not provided
    Model = maps:get(model, Config, <<"gemini-3.5-flash">>),
    ApiKey = get_api_key(Config),

    Url =
        "https://generativelanguage.googleapis.com/v1beta/models/" ++
            binary_to_list(Model) ++ ":generateContent?key=" ++ binary_to_list(ApiKey),

    %% Build the payload
    {SystemInstruction, Contents} = build_contents(Memory, <<>>, []),

    Payload0 = #{<<"contents">> => Contents},
    Payload1 =
        case SystemInstruction of
            <<>> -> Payload0;
            Sys -> Payload0#{<<"system_instruction">> => #{<<"parts">> => #{<<"text">> => Sys}}}
        end,

    %% Add generation config (bells and whistles)
    GenConfig = build_gen_config(Config),
    Payload2 =
        case maps:size(GenConfig) of
            0 -> Payload1;
            _ -> Payload1#{<<"generationConfig">> => GenConfig}
        end,

    %% Add tools if present
    Payload3 = case Tools of
        [] -> Payload2;
        _ ->
            Declarations = [Mod:schema() || Mod <- Tools],
            Payload2#{<<"tools">> => [#{<<"function_declarations">> => Declarations}]}
    end,

    JsonBody = jsx:encode(Payload3),

    %% HTTP Request
    Headers = [{"Content-Type", "application/json"}],
    Request = {Url, Headers, "application/json", JsonBody},
    %% Simplified SSL
    HttpOptions = [{ssl, [{verify, verify_none}]}],
    Options = [{body_format, binary}],

    case httpc:request(post, Request, HttpOptions, Options) of
        {ok, {{_Version, 200, _ReasonPhrase}, _Headers, Body}} ->
            ResponseMap = jsx:decode(Body, [return_maps]),
            parse_response(ResponseMap);
        {ok, {{_Version, StatusCode, ReasonPhrase}, _Headers, Body}} ->
            {error, {StatusCode, ReasonPhrase, Body}};
        {error, Reason} ->
            {error, Reason}
    end.

get_api_key(Config) ->
    case maps:find(api_key, Config) of
        {ok, Key} ->
            Key;
        error ->
            case os:getenv("GEMINI_API_KEY") of
                false -> throw({error, missing_api_key});
                KeyStr -> list_to_binary(KeyStr)
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
        {Name, Args, Sig} = case Call of
            {N, A} -> {N, A, undefined};
            {N, A, S} -> {N, A, S}
        end,
        FuncCall = #{
            <<"name">> => to_binary(Name),
            <<"args">> => Args
        },
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
    %% Look for function calls first
    ToolCallsWithSigs = lists:filtermap(
        fun
            (Part = #{<<"functionCall">> := FuncCall}) ->
                Name = maps:get(<<"name">>, FuncCall),
                Args = maps:get(<<"args">>, FuncCall, #{}),
                Sig = maps:get(<<"thoughtSignature">>, Part, undefined),
                {true, {Name, Args, Sig}};
            (_) -> false
        end, Parts),
    
    %% Propagate the thoughtSignature to all tool calls in parallel array
    GlobalSig = lists:foldl(fun
        ({_, _, S}, _Acc) when S =/= undefined -> S;
        (_, Acc) -> Acc
    end, undefined, ToolCallsWithSigs),
    
    ToolCalls = [{N, A, GlobalSig} || {N, A, _} <- ToolCallsWithSigs],
    
    case ToolCalls of
        [] ->
            %% Try to extract text
            TextParts = [Text || #{<<"text">> := Text} <- Parts],
            case TextParts of
                [] -> {error, empty_response};
                [Text|_] -> {ok, Text}
            end;
        _ ->
            {tool_calls, ToolCalls}
    end;
parse_response(_) ->
    {error, invalid_response}.

to_binary(Atom) when is_atom(Atom) -> atom_to_binary(Atom, utf8);
to_binary(Str) when is_list(Str) -> unicode:characters_to_binary(Str);
to_binary(Bin) when is_binary(Bin) -> Bin.
