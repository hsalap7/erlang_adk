%% @doc Strict model toolset boundary for an external code sandbox.
%%
%% The toolset validates and bounds every model-controlled field before a
%% trusted `adk_code_executor' adapter sees it. It never evaluates code in the
%% VM, invokes a shell, opens a port, or accepts an executable path.
-module(adk_code_toolset).

-export([new/1, compile/1, capabilities/0, schemas/1, resolved_call/4]).

-define(MAX_LANGUAGES, 32).
-define(MAX_LANGUAGE_BYTES, 64).
-define(MAX_CODE_CEILING, 1048576).
-define(MAX_STDIN_CEILING, 1048576).
-define(MAX_FILES_CEILING, 64).
-define(MAX_FILE_CEILING, 4194304).
-define(MAX_TOTAL_FILES_CEILING, 16777216).
-define(MAX_OUTPUT_CEILING, 8388608).
-define(MAX_TIMEOUT_MS, 300000).

-type compiled() :: map().
-export_type([compiled/0]).

-spec new(map()) ->
    {ok, adk_toolset:descriptor()} | {error, term()}.
new(Config) ->
    case compile(Config) of
        {ok, Compiled} -> adk_toolset:new(?MODULE, Compiled);
        {error, _} = Error -> Error
    end.

-spec compile(map()) -> {ok, compiled()} | {error, term()}.
compile(Config) when is_map(Config) ->
    Known = [executor, languages, max_code_bytes, max_stdin_bytes,
             max_files, max_file_bytes, max_total_file_bytes,
             max_output_bytes, timeout, parallel_safe, context_keys],
    Unknown = maps:without(Known, Config),
    Executor = maps:get(executor, Config, undefined),
    Languages0 = maps:get(languages, Config, []),
    Limits = #{max_code_bytes => maps:get(max_code_bytes, Config, 65536),
               max_stdin_bytes => maps:get(max_stdin_bytes, Config, 65536),
               max_files => maps:get(max_files, Config, 16),
               max_file_bytes => maps:get(max_file_bytes, Config, 1048576),
               max_total_file_bytes => maps:get(
                                         max_total_file_bytes, Config,
                                         4194304),
               max_output_bytes => maps:get(max_output_bytes, Config,
                                             1048576)},
    Timeout = maps:get(timeout, Config, 30000),
    ParallelSafe = maps:get(parallel_safe, Config, false),
    ContextKeys = maps:get(context_keys, Config,
                           [invocation_id, session_id, trace_id]),
    case {map_size(Unknown), validate_executor(Executor),
          validate_languages(Languages0), validate_limits(Limits),
          valid_timeout(Timeout), is_boolean(ParallelSafe),
          validate_context_keys(ContextKeys)} of
        {Size, _, _, _, _, _, _} when Size > 0 ->
            {error, {unknown_code_toolset_config,
                     lists:sort(maps:keys(Unknown))}};
        {_, {error, _} = Error, _, _, _, _, _} -> Error;
        {_, _, {error, _} = Error, _, _, _, _} -> Error;
        {_, _, _, {error, _} = Error, _, _, _} -> Error;
        {_, _, _, _, false, _, _} -> {error, invalid_code_timeout};
        {_, _, _, _, _, false, _} -> {error, invalid_parallel_safe};
        {_, _, _, _, _, _, {error, _} = Error} -> Error;
        {0, {ok, SafeExecutor}, {ok, Languages}, {ok, SafeLimits},
         true, true, {ok, SafeContextKeys}} ->
            {ok, #{executor => SafeExecutor,
                   languages => Languages,
                   limits => SafeLimits,
                   timeout => Timeout,
                   parallel_safe => ParallelSafe,
                   context_keys => SafeContextKeys}}
    end;
compile(_Config) ->
    {error, invalid_code_toolset_config}.

-spec capabilities() -> map().
capabilities() ->
    #{external_sandbox_required => true,
      in_process_execution => false,
      bounded_input => true,
      bounded_output => true,
      shell_fallback => false}.

-spec schemas(compiled()) -> [map()].
schemas(#{languages := Languages}) ->
    [#{<<"name">> => <<"execute_code">>,
       <<"description">> =>
           <<"Execute code in the application's isolated external sandbox">>,
       <<"parameters">> =>
           #{<<"type">> => <<"object">>,
             <<"properties">> =>
                 #{<<"language">> =>
                       #{<<"type">> => <<"string">>,
                         <<"enum">> => Languages},
                   <<"code">> => #{<<"type">> => <<"string">>},
                   <<"stdin">> => #{<<"type">> => <<"string">>},
                   <<"files">> =>
                       #{<<"type">> => <<"array">>,
                         <<"items">> =>
                             #{<<"type">> => <<"object">>,
                               <<"properties">> =>
                                   #{<<"name">> =>
                                         #{<<"type">> => <<"string">>},
                                     <<"content">> =>
                                         #{<<"type">> => <<"string">>}},
                               <<"required">> =>
                                   [<<"name">>, <<"content">>],
                               <<"additionalProperties">> => false}}},
             <<"required">> => [<<"language">>, <<"code">>],
             <<"additionalProperties">> => false}}];
schemas(_Invalid) ->
    erlang:error(invalid_compiled_code_toolset).

-spec resolved_call(compiled(), binary(), map(), map()) ->
    {ok, adk_tool_executor:resolved_call()} | {error, term()}.
resolved_call(Compiled, <<"execute_code">>, Args, Context)
  when is_map(Compiled), is_map(Args), is_map(Context) ->
    case validate_request(Args, Compiled) of
        {ok, Request} ->
            SafeContext = sandbox_context(
                            Context, maps:get(context_keys, Compiled)),
            Executor = maps:get(executor, Compiled),
            MaxOutput = maps:get(max_output_bytes,
                                 maps:get(limits, Compiled)),
            Execute = fun() ->
                invoke_executor(Executor, Request, SafeContext, MaxOutput)
            end,
            {ok, #{name => <<"execute_code">>,
                   args => Args,
                   execute => Execute,
                   parallel_safe => maps:get(parallel_safe, Compiled),
                   pause_capable => false,
                   timeout => maps:get(timeout, Compiled)}};
        {error, _} = Error -> Error
    end;
resolved_call(_Compiled, _Name, _Args, _Context) ->
    {error, unknown_tool}.

validate_executor({Module, Handle}) when is_atom(Module),
                                         Module =/= undefined ->
    case code:ensure_loaded(Module) of
        {module, Module} ->
            case erlang:function_exported(Module, execute, 3) of
                true -> {ok, {Module, Handle}};
                false -> {error, {invalid_code_executor, Module}}
            end;
        {error, Reason} ->
            {error, {code_executor_unavailable, Module, Reason}}
    end;
validate_executor(_Executor) ->
    {error, invalid_code_executor}.

validate_languages(Languages) when is_list(Languages), Languages =/= [] ->
    case bounded_list_length(Languages, ?MAX_LANGUAGES) of
        {ok, _} ->
            case lists:all(fun valid_language/1, Languages) andalso
                 length(Languages) =:= length(lists:usort(Languages)) of
                true -> {ok, Languages};
                false -> {error, invalid_code_languages}
            end;
        _ -> {error, invalid_code_languages}
    end;
validate_languages(_Languages) ->
    {error, invalid_code_languages}.

valid_language(Language) when is_binary(Language),
                              byte_size(Language) > 0,
                              byte_size(Language) =< ?MAX_LANGUAGE_BYTES ->
    valid_utf8(Language) andalso
    lists:all(fun(C) ->
                      (C >= $a andalso C =< $z) orelse
                      (C >= $0 andalso C =< $9) orelse
                      C =:= $+ orelse C =:= $- orelse C =:= $_
              end, binary_to_list(Language));
valid_language(_) -> false.

validate_limits(Limits) ->
    Checks = [{max_code_bytes, ?MAX_CODE_CEILING},
              {max_stdin_bytes, ?MAX_STDIN_CEILING},
              {max_files, ?MAX_FILES_CEILING},
              {max_file_bytes, ?MAX_FILE_CEILING},
              {max_total_file_bytes, ?MAX_TOTAL_FILES_CEILING},
              {max_output_bytes, ?MAX_OUTPUT_CEILING}],
    case lists:all(
           fun({Key, Ceiling}) ->
               Value = maps:get(Key, Limits),
               is_integer(Value) andalso Value > 0 andalso Value =< Ceiling
           end, Checks) andalso
         maps:get(max_file_bytes, Limits) =<
             maps:get(max_total_file_bytes, Limits) of
        true -> {ok, Limits};
        false -> {error, invalid_code_limits}
    end.

validate_context_keys(Keys) when is_list(Keys) ->
    Allowed = [invocation_id, session_id, trace_id, principal],
    case bounded_list_length(Keys, length(Allowed)) of
        {ok, _} ->
            case lists:all(fun(Key) -> lists:member(Key, Allowed) end, Keys)
                 andalso length(Keys) =:= length(lists:usort(Keys)) of
                true -> {ok, Keys};
                false -> {error, invalid_code_context_keys}
            end;
        _ -> {error, invalid_code_context_keys}
    end;
validate_context_keys(_Keys) -> {error, invalid_code_context_keys}.

validate_request(Args, Compiled) ->
    Allowed = [<<"language">>, <<"code">>, <<"stdin">>, <<"files">>],
    Unknown = maps:without(Allowed, Args),
    Language = maps:get(<<"language">>, Args, undefined),
    Code = maps:get(<<"code">>, Args, undefined),
    Stdin = maps:get(<<"stdin">>, Args, <<>>),
    Files = maps:get(<<"files">>, Args, []),
    Limits = maps:get(limits, Compiled),
    case {map_size(Unknown),
          lists:member(Language, maps:get(languages, Compiled)),
          valid_text(Code, maps:get(max_code_bytes, Limits), false),
          valid_text(Stdin, maps:get(max_stdin_bytes, Limits), true),
          validate_files(Files, Limits)} of
        {Size, _, _, _, _} when Size > 0 ->
            {error, {invalid_code_request, unknown_fields}};
        {0, true, true, true, {ok, SafeFiles}} ->
            {ok, #{<<"language">> => Language,
                   <<"code">> => Code,
                   <<"stdin">> => Stdin,
                   <<"files">> => SafeFiles}};
        {0, false, _, _, _} ->
            {error, {invalid_code_request, language_not_allowed}};
        {0, _, false, _, _} ->
            {error, {invalid_code_request, invalid_code}};
        {0, _, _, false, _} ->
            {error, {invalid_code_request, invalid_stdin}};
        {0, _, _, _, {error, Reason}} ->
            {error, {invalid_code_request, Reason}}
    end.

validate_files(Files, Limits) when is_list(Files) ->
    case bounded_list_length(Files, maps:get(max_files, Limits)) of
        {ok, _} -> validate_files(Files, Limits, [], 0, #{});
        _ -> {error, too_many_files}
    end;
validate_files(_Files, _Limits) -> {error, invalid_files}.

validate_files([], _Limits, Acc, _Total, _Names) ->
    {ok, lists:reverse(Acc)};
validate_files([File | Rest], Limits, Acc, Total0, Names)
  when is_map(File) ->
    case maps:keys(File) of
        Keys when length(Keys) =:= 2 ->
            Name = maps:get(<<"name">>, File, undefined),
            Content = maps:get(<<"content">>, File, undefined),
            Total = case is_binary(Content) of
                true -> Total0 + byte_size(Content);
                false -> Total0
            end,
            case valid_file_name(Name) andalso
                 not maps:is_key(Name, Names) andalso
                 valid_text(Content, maps:get(max_file_bytes, Limits), true)
                 andalso Total =< maps:get(max_total_file_bytes, Limits) of
                true ->
                    Safe = #{<<"name">> => Name, <<"content">> => Content},
                    validate_files(Rest, Limits, [Safe | Acc], Total,
                                   Names#{Name => true});
                false -> {error, invalid_file}
            end;
        _ -> {error, invalid_file}
    end;
validate_files(_Improper, _Limits, _Acc, _Total, _Names) ->
    {error, invalid_files}.

valid_file_name(Name) when is_binary(Name), byte_size(Name) > 0,
                           byte_size(Name) =< 256 ->
    Parts = binary:split(Name, <<"/">>, [global]),
    valid_utf8(Name) andalso
    not filename_absolute(Name) andalso
    binary:match(Name, <<"\\">>) =:= nomatch andalso
    binary:match(Name, <<":">>) =:= nomatch andalso
    lists:all(fun(<<>>) -> false;
                 (<<".">>) -> false;
                 (<<"..">>) -> false;
                 (Part) -> binary:match(Part, <<0>>) =:= nomatch
              end, Parts);
valid_file_name(_) -> false.

filename_absolute(<<"/", _/binary>>) -> true;
filename_absolute(<<_Drive, $:, _/binary>>) -> true;
filename_absolute(_) -> false.

valid_text(Value, Max, AllowEmpty) when is_binary(Value) ->
    Size = byte_size(Value),
    (AllowEmpty orelse Size > 0) andalso Size =< Max andalso valid_utf8(Value);
valid_text(_Value, _Max, _AllowEmpty) -> false.

sandbox_context(Context, Keys) ->
    Selected = maps:with(Keys, Context),
    case adk_json:normalize(adk_secret_redactor:redact(Selected)) of
        {ok, Safe} when is_map(Safe) -> Safe;
        _ -> #{}
    end.

invoke_executor({Module, Handle}, Request, Context, MaxOutput) ->
    Raw = try Module:execute(Handle, Request, Context) of
        Result -> Result
    catch
        Class:Reason -> {error, {executor_exception, Class, Reason}}
    end,
    normalize_executor_result(Raw, MaxOutput).

normalize_executor_result({ok, Output}, MaxOutput) when is_map(Output) ->
    case adk_json:normalize(Output) of
        {ok, Json} ->
            case byte_size(jsx:encode(Json)) =< MaxOutput of
                true -> {ok, Json};
                false -> {error, code_output_too_large}
            end;
        {error, _} -> {error, invalid_code_output}
    end;
normalize_executor_result({error, Reason}, _MaxOutput) ->
    Safe0 = adk_secret_redactor:redact(Reason),
    Safe = case adk_json:normalize(Safe0) of
        {ok, Json} -> Json;
        {error, _} -> <<"redacted_executor_error">>
    end,
    {error, #{<<"code">> => <<"sandbox_error">>, <<"detail">> => Safe}};
normalize_executor_result(_Other, _MaxOutput) ->
    {error, invalid_code_executor_result}.

valid_timeout(Value) ->
    is_integer(Value) andalso Value > 0 andalso Value =< ?MAX_TIMEOUT_MS.

bounded_list_length(List, Max) ->
    bounded_list_length(List, Max, 0).

bounded_list_length([], _Max, Count) -> {ok, Count};
bounded_list_length([_ | Rest], Max, Count) when Count < Max ->
    bounded_list_length(Rest, Max, Count + 1);
bounded_list_length([_ | _], _Max, _Count) -> too_many;
bounded_list_length(_Improper, _Max, _Count) -> improper.

valid_utf8(Value) ->
    case unicode:characters_to_binary(Value, utf8, utf8) of
        Value -> true;
        _ -> false
    end.
