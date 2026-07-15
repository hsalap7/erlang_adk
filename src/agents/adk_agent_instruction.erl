%% @doc Safe static/dynamic instruction resolution for an agent specification.
%%
%% Dynamic providers receive a deliberately narrow read-only context. Service
%% handles, credential references, authentication values, and arbitrary runner
%% internals are never passed to provider code. Template placeholders can read
%% only the supplied scoped-state snapshot or an artifact from the exact scope
%% supplied by the runner.
-module(adk_agent_instruction).

-export([compile/2, resolve/3, is_secret_key/1]).

-type instruction() :: {static, [segment()]} |
                       {dynamic, module(), atom()}.
-type segment() :: {text, binary()} |
                   {placeholder, state | artifact, binary(), boolean()}.
-type error_reason() :: invalid_instruction | instruction_too_large |
                        invalid_instruction_context |
                        invalid_instruction_callback |
                        instruction_callback_timeout |
                        instruction_callback_failed |
                        instruction_callback_error |
                        invalid_instruction_callback_result |
                        {secret_template_key, binary()} |
                        {instruction_state_not_found, binary()} |
                        {instruction_artifact_not_found, binary()} |
                        {instruction_artifact_unavailable, binary()} |
                        {invalid_instruction_artifact, binary()}.

-export_type([instruction/0, error_reason/0]).

-define(TEMPLATE_PATTERN,
        <<"\\{\\{\\s*([^{}]+?)\\s*\\}\\}|\\{\\s*([^{}]+?)\\s*\\}">>).

-spec compile(binary() | string() | {dynamic, module(), atom()},
              pos_integer()) ->
    {ok, instruction()} | {error, error_reason()}.
compile(Value, MaxBytes) when is_integer(MaxBytes), MaxBytes > 0 ->
    case Value of
        {dynamic, Module, Function}
          when is_atom(Module), is_atom(Function) ->
            compile_dynamic(Module, Function);
        _ ->
            case instruction_binary(Value) of
                {ok, Template} when byte_size(Template) =< MaxBytes ->
                    case parse_template(Template) of
                        {ok, Segments} -> {ok, {static, Segments}};
                        {error, _} = Error -> Error
                    end;
                {ok, _TooLarge} -> {error, instruction_too_large};
                error -> {error, invalid_instruction}
            end
    end;
compile(_Value, _MaxBytes) ->
    {error, invalid_instruction}.

compile_dynamic(Module, Function) ->
    case code:ensure_loaded(Module) of
        {module, Module} ->
            case erlang:function_exported(Module, Function, 1) of
                true -> {ok, {dynamic, Module, Function}};
                false -> {error, invalid_instruction_callback}
            end;
        {error, _Reason} ->
            {error, invalid_instruction_callback}
    end.

%% @doc Resolve one instruction. Options require timeout_ms,
%% artifact_timeout_ms, and max_bytes.
-spec resolve(instruction(), map(), map()) ->
    {ok, binary()} | {error, error_reason()}.
resolve(Instruction, Context0,
        #{timeout_ms := Timeout,
          artifact_timeout_ms := ArtifactTimeout,
          max_bytes := MaxBytes})
  when is_map(Context0), is_integer(Timeout), Timeout > 0,
       is_integer(ArtifactTimeout), ArtifactTimeout > 0,
       is_integer(MaxBytes), MaxBytes > 0 ->
    case sanitize_context(Context0) of
        {ok, ReadonlyContext, RuntimeContext} ->
            case instruction_segments(Instruction, ReadonlyContext,
                                      Timeout, MaxBytes) of
                {ok, Segments} ->
                    resolve_segments(Segments, RuntimeContext,
                                     ArtifactTimeout, MaxBytes, [], 0);
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end;
resolve(_Instruction, _Context, _Options) ->
    {error, invalid_instruction_context}.

instruction_segments({static, Segments}, _Context, _Timeout, _MaxBytes)
  when is_list(Segments) ->
    {ok, Segments};
instruction_segments({dynamic, Module, Function}, Context, Timeout, MaxBytes) ->
    case invoke_dynamic(Module, Function, Context, Timeout) of
        {ok, Template} when byte_size(Template) =< MaxBytes ->
            parse_template(Template);
        {ok, _TooLarge} ->
            {error, instruction_too_large};
        {error, _} = Error ->
            Error
    end;
instruction_segments(_Instruction, _Context, _Timeout, _MaxBytes) ->
    {error, invalid_instruction}.

sanitize_context(Context) ->
    case maps:get(state, Context, #{}) of
        State0 when is_map(State0) ->
            case adk_json:normalize(State0) of
                {ok, State} when is_map(State) ->
                    SafeState = strip_secret_values(State),
                    Readonly0 = #{state => SafeState},
                    Readonly = copy_scope_fields(
                                 [app_name, user_id, session_id,
                                  invocation_id], Context, Readonly0),
                    Runtime = #{state => SafeState,
                                artifact_service =>
                                    maps:get(artifact_service, Context,
                                             undefined),
                                artifact_scope =>
                                    maps:get(artifact_scope, Context,
                                             undefined)},
                    {ok, Readonly, Runtime};
                _ -> {error, invalid_instruction_context}
            end;
        _ ->
            {error, invalid_instruction_context}
    end.

copy_scope_fields([], _Source, Acc) -> Acc;
copy_scope_fields([Key | Rest], Source, Acc) ->
    Acc1 = case maps:find(Key, Source) of
        {ok, Value} when is_binary(Value) -> Acc#{Key => Value};
        _ -> Acc
    end,
    copy_scope_fields(Rest, Source, Acc1).

strip_secret_values(Map) when is_map(Map) ->
    maps:from_list([
        {Key, strip_secret_values(Value)}
        || {Key, Value} <- maps:to_list(Map),
           not is_secret_key(Key)
    ]);
strip_secret_values(List) when is_list(List) ->
    [strip_secret_values(Value) || Value <- List];
strip_secret_values(Value) -> Value.

invoke_dynamic(Module, Function, Context, Timeout) ->
    Caller = self(),
    Alias = erlang:alias([explicit_unalias]),
    {Coordinator, Monitor} = spawn_monitor(fun() ->
        dynamic_coordinator(Caller, Alias, Module, Function, Context, Timeout)
    end),
    receive
        {Alias, Result} ->
            _ = erlang:unalias(Alias),
            _ = erlang:demonitor(Monitor, [flush]),
            Result;
        {'DOWN', Monitor, process, Coordinator, _Reason} ->
            _ = erlang:unalias(Alias),
            {error, instruction_callback_failed}
    after Timeout + 100 ->
        _ = erlang:unalias(Alias),
        exit(Coordinator, kill),
        receive
            {'DOWN', Monitor, process, Coordinator, _Reason} -> ok
        after 100 ->
            _ = erlang:demonitor(Monitor, [flush])
        end,
        {error, instruction_callback_timeout}
    end.

dynamic_coordinator(Caller, ReplyAlias, Module, Function, Context, Timeout) ->
    process_flag(trap_exit, true),
    CallerMonitor = erlang:monitor(process, Caller),
    Coordinator = self(),
    Worker = spawn_link(fun() ->
        Result = dynamic_result(Module, Function, Context),
        Coordinator ! {instruction_callback_result, self(), Result}
    end),
    receive
        {instruction_callback_result, Worker, Result} ->
            unlink(Worker),
            _ = erlang:demonitor(CallerMonitor, [flush]),
            send_alias(ReplyAlias, Result);
        {'EXIT', Worker, _Reason} ->
            _ = erlang:demonitor(CallerMonitor, [flush]),
            send_alias(ReplyAlias, {error, instruction_callback_failed});
        {'DOWN', CallerMonitor, process, Caller, _Reason} ->
            exit(Worker, kill),
            ok
    after Timeout ->
        exit(Worker, kill),
        receive {'EXIT', Worker, _} -> ok after 50 -> ok end,
        _ = erlang:demonitor(CallerMonitor, [flush]),
        send_alias(ReplyAlias, {error, instruction_callback_timeout})
    end.

dynamic_result(Module, Function, Context) ->
    try apply(Module, Function, [Context]) of
        {ok, Value} -> normalize_dynamic_value(Value);
        {error, _Reason} -> {error, instruction_callback_error};
        Value -> normalize_dynamic_value(Value)
    catch
        _Class:_Reason -> {error, instruction_callback_failed}
    end.

normalize_dynamic_value(Value) ->
    case instruction_binary(Value) of
        {ok, Binary} -> {ok, Binary};
        error -> {error, invalid_instruction_callback_result}
    end.

send_alias(Alias, Result) ->
    _ = catch erlang:send(Alias, {Alias, Result}, [nosuspend]),
    ok.

parse_template(Template) ->
    case re:run(Template, ?TEMPLATE_PATTERN,
                [global, unicode, {capture, [0, 1, 2], index}]) of
        nomatch -> {ok, [{text, Template}]};
        {match, Matches} ->
            build_segments(Template, Matches, 0, []);
        {error, _} ->
            {error, invalid_instruction}
    end.

build_segments(Template, [], Position, Acc) ->
    TailSize = byte_size(Template) - Position,
    Tail = binary:part(Template, Position, TailSize),
    {ok, merge_text_segments(lists:reverse(add_text(Tail, Acc)), [])};
build_segments(Template, [[{Start, Length}, First, Second] | Rest],
               Position, Acc) ->
    Prefix = binary:part(Template, Position, Start - Position),
    Raw = binary:part(Template, Start, Length),
    KeyRange = case First of
        {-1, 0} -> Second;
        _ -> First
    end,
    {KeyStart, KeyLength} = KeyRange,
    Key0 = binary:part(Template, KeyStart, KeyLength),
    Key = string:trim(Key0),
    Acc1 = add_text(Prefix, Acc),
    case parse_placeholder(Key) of
        {ok, Source, Name, Optional} ->
            build_segments(Template, Rest, Start + Length,
                           [{placeholder, Source, Name, Optional} | Acc1]);
        literal ->
            build_segments(Template, Rest, Start + Length,
                           add_text(Raw, Acc1));
        {error, _} = Error ->
            Error
    end.

parse_placeholder(Key0) when byte_size(Key0) > 0 ->
    {Key, Optional} = optional_key(Key0),
    case Key of
        <<"artifact.", Name/binary>> ->
            case valid_artifact_name(Name) of
                true ->
                    case is_secret_key(Name) of
                        true -> {error, {secret_template_key, Name}};
                        false -> {ok, artifact, Name, Optional}
                    end;
                false -> literal
            end;
        _ ->
            case valid_state_key(Key) of
                true ->
                    case is_secret_key(Key) of
                        true -> {error, {secret_template_key, Key}};
                        false -> {ok, state, Key, Optional}
                    end;
                false -> literal
            end
    end;
parse_placeholder(_Key) -> literal.

optional_key(Key) ->
    Size = byte_size(Key),
    case binary:at(Key, Size - 1) of
        $? when Size > 1 -> {binary:part(Key, 0, Size - 1), true};
        _ -> {Key, false}
    end.

valid_state_key(Key) ->
    case re:run(Key,
                <<"^(?:(?:app|user|temp):)?[A-Za-z_][A-Za-z0-9_.-]*$">>,
                [{capture, none}]) of
        match -> true;
        nomatch -> false
    end.

valid_artifact_name(Name) when byte_size(Name) > 0 ->
    Parts = binary:split(Name, <<"/">>, [global]),
    valid_utf8(Name) andalso
    lists:all(fun(<<>>) -> false;
                 (<<".">>) -> false;
                 (<<"..">>) -> false;
                 (Part) -> binary:match(Part, <<0>>) =:= nomatch
              end, Parts);
valid_artifact_name(_Name) -> false.

resolve_segments([], _Runtime, _ArtifactTimeout, _MaxBytes, Acc, _Size) ->
    {ok, iolist_to_binary(lists:reverse(Acc))};
resolve_segments([{text, Text} | Rest], Runtime, ArtifactTimeout,
                 MaxBytes, Acc, Size) ->
    append_resolved(Text, Rest, Runtime, ArtifactTimeout,
                    MaxBytes, Acc, Size);
resolve_segments([{placeholder, state, Key, Optional} | Rest],
                 Runtime, ArtifactTimeout, MaxBytes, Acc, Size) ->
    State = maps:get(state, Runtime),
    case maps:find(Key, State) of
        {ok, Value} ->
            case json_text(Value) of
                {ok, Text} ->
                    append_resolved(Text, Rest, Runtime, ArtifactTimeout,
                                    MaxBytes, Acc, Size);
                error -> {error, invalid_instruction_context}
            end;
        error when Optional ->
            resolve_segments(Rest, Runtime, ArtifactTimeout,
                             MaxBytes, Acc, Size);
        error ->
            {error, {instruction_state_not_found, Key}}
    end;
resolve_segments([{placeholder, artifact, Name, Optional} | Rest],
                 Runtime, ArtifactTimeout, MaxBytes, Acc, Size) ->
    case resolve_artifact(Name, Optional, Runtime, ArtifactTimeout) of
        {ok, Text} ->
            append_resolved(Text, Rest, Runtime, ArtifactTimeout,
                            MaxBytes, Acc, Size);
        {error, _} = Error -> Error
    end.

append_resolved(Text, Rest, Runtime, ArtifactTimeout,
                MaxBytes, Acc, Size) ->
    NewSize = Size + byte_size(Text),
    case NewSize =< MaxBytes of
        true -> resolve_segments(Rest, Runtime, ArtifactTimeout,
                                 MaxBytes, [Text | Acc], NewSize);
        false -> {error, instruction_too_large}
    end.

resolve_artifact(Name, Optional,
                 #{artifact_service := undefined}, _Timeout) ->
    missing_artifact(Name, Optional);
resolve_artifact(Name, Optional,
                 #{artifact_service := ServiceRef,
                   artifact_scope := Scope}, Timeout) ->
    case valid_artifact_scope(Scope) of
        true ->
            case adk_service_ref:validate(artifact, ServiceRef) of
                {ok, ValidRef} ->
                    artifact_result(Name, Optional,
                                    adk_service_ref:call(
                                      ValidRef, get,
                                      [Scope, Name, latest], Timeout));
                {error, _} ->
                    {error, {instruction_artifact_unavailable, Name}}
            end;
        false ->
            {error, {invalid_instruction_artifact, Name}}
    end.

artifact_result(_Name, _Optional, {ok, #{data := Data}})
  when is_binary(Data) ->
    artifact_text(Data);
artifact_result(_Name, _Optional, {ok, #{<<"data">> := Data}})
  when is_binary(Data) ->
    artifact_text(Data);
artifact_result(Name, Optional, {error, not_found}) ->
    missing_artifact(Name, Optional);
artifact_result(Name, _Optional, _Other) ->
    {error, {instruction_artifact_unavailable, Name}}.

artifact_text(Data) ->
    case valid_utf8(Data) of
        true -> {ok, Data};
        false -> {error, {invalid_instruction_artifact, <<"content">>}}
    end.

missing_artifact(_Name, true) -> {ok, <<>>};
missing_artifact(Name, false) ->
    {error, {instruction_artifact_not_found, Name}}.

valid_artifact_scope({app, App}) -> valid_scope_part(App);
valid_artifact_scope({user, App, User}) ->
    valid_scope_part(App) andalso valid_scope_part(User);
valid_artifact_scope({session, App, User, Session}) ->
    valid_scope_part(App) andalso valid_scope_part(User) andalso
    valid_scope_part(Session);
valid_artifact_scope(_) -> false.

valid_scope_part(Value) when is_binary(Value), byte_size(Value) > 0 ->
    valid_utf8(Value) andalso binary:match(Value, <<0>>) =:= nomatch;
valid_scope_part(_) -> false.

json_text(Value) when is_binary(Value) -> {ok, Value};
json_text(Value) ->
    try jsx:encode(Value) of
        Encoded when is_binary(Encoded) -> {ok, Encoded}
    catch
        _:_ -> error
    end.

add_text(<<>>, Acc) -> Acc;
add_text(Text, Acc) -> [{text, Text} | Acc].

merge_text_segments([], Acc) -> lists:reverse(Acc);
merge_text_segments([{text, Text} | Rest], [{text, Previous} | AccRest]) ->
    merge_text_segments(Rest, [{text, <<Previous/binary, Text/binary>>} | AccRest]);
merge_text_segments([Segment | Rest], Acc) ->
    merge_text_segments(Rest, [Segment | Acc]).

instruction_binary(Value) when is_binary(Value) ->
    case valid_utf8(Value) of true -> {ok, Value}; false -> error end;
instruction_binary(Value) when is_list(Value) ->
    try unicode:characters_to_binary(Value) of
        Binary when is_binary(Binary) -> {ok, Binary};
        _ -> error
    catch
        _:_ -> error
    end;
instruction_binary(_Value) -> error.

valid_utf8(Binary) ->
    case unicode:characters_to_binary(Binary, utf8, utf8) of
        Binary -> true;
        _ -> false
    end.

%% @doc Conservative credential-key detector shared by template validation and
%% the dynamic callback's state projection.
-spec is_secret_key(term()) -> boolean().
is_secret_key(Key) when is_atom(Key) ->
    is_secret_key(atom_to_binary(Key, utf8));
is_secret_key(Key) when is_list(Key) ->
    case instruction_binary(Key) of
        {ok, Binary} -> is_secret_key(Binary);
        error -> true
    end;
is_secret_key(Key) when is_binary(Key) ->
    Lower0 = string:lowercase(Key),
    Lower1 = binary:replace(Lower0, <<"-">>, <<"_">>, [global]),
    Lower2 = binary:replace(Lower1, <<".">>, <<"_">>, [global]),
    Lower = case binary:split(Lower2, <<":">>, [global]) of
        Parts -> lists:last(Parts)
    end,
    Exact = [<<"authorization">>, <<"proxy_authorization">>,
             <<"api_key">>, <<"apikey">>, <<"password">>, <<"passwd">>,
             <<"secret">>, <<"client_secret">>, <<"clientsecret">>,
             <<"access_token">>, <<"accesstoken">>,
             <<"refresh_token">>, <<"refreshtoken">>,
             <<"id_token">>, <<"idtoken">>, <<"token">>,
             <<"credential">>, <<"credentials">>, <<"credential_ref">>,
             <<"credentialref">>, <<"private_key">>, <<"privatekey">>,
             <<"client_assertion">>, <<"clientassertion">>, <<"bearer">>,
             <<"session_token">>, <<"security_token">>, <<"cookie">>,
             <<"set_cookie">>, <<"otp">>, <<"pin">>],
    lists:member(Lower, Exact) orelse
    lists:any(fun(Suffix) -> binary_suffix(Lower, Suffix) end,
              [<<"_api_key">>, <<"_password">>, <<"_secret">>,
               <<"_token">>, <<"_credential">>, <<"_credentials">>,
               <<"_private_key">>]);
is_secret_key(_Key) -> true.

binary_suffix(Binary, Suffix) ->
    BinarySize = byte_size(Binary),
    SuffixSize = byte_size(Suffix),
    BinarySize >= SuffixSize andalso
    binary:part(Binary, BinarySize - SuffixSize, SuffixSize) =:= Suffix.
