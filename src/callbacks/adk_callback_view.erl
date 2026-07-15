%% @doc Least-privilege values exposed to callbacks and model plugins.
%%
%% Agent/provider configuration is operational authority. Callbacks need model
%% identity and generation settings, not API keys, HTTP clients, credential
%% stores, process handles, callback handles, or provider-private options.
-module(adk_callback_view).

-export([config/1, runtime_config/1, model_request/1, callback_args/2,
         plugin_value/2]).

-spec config(term()) -> map().
config(Config) when is_map(Config) ->
    project_config(Config);
config(_) ->
    #{}.

%% Runner-visible agent metadata. Provider authority stays inside adk_agent;
%% this projection contains only callback module identities, model metadata,
%% the internal invocation API marker, and validated global-instruction source
%% required to preserve root scope during delegation.
-spec runtime_config(term()) -> map().
runtime_config(Config) when is_map(Config) ->
    Base0 = project_config(Config),
    Base1 = case maps:get(callbacks, Config, []) of
        Handlers when is_list(Handlers) ->
            Base0#{callbacks => [Handler || Handler <- Handlers,
                                            is_atom(Handler)]};
        _ -> Base0
    end,
    Base2 = case maps:get('$adk_invocation_context_api', Config, undefined) of
        Version when is_integer(Version), Version >= 0 ->
            Base1#{'$adk_invocation_context_api' => Version};
        _ -> Base1
    end,
    Base3 = copy_instruction_source(global_instruction, Config, Base2),
    copy_instruction_source(
      '$adk_inherited_global_instruction', Config, Base3);
runtime_config(_) -> #{}.

-spec model_request(term()) -> term().
model_request(Request) when is_map(Request) ->
    Base0 = maps:with([memory, tools, streaming], Request),
    Base = prune(Base0),
    case maps:find(config, Request) of
        {ok, Config} -> Base#{config => project_config(Config)};
        error -> Base
    end;
model_request(_) ->
    #{}.

%% Central hook adapter used by adk_callbacks. Successful model/tool values are
%% preserved so callback intervention semantics remain backwards compatible.
-spec callback_args(atom(), [term()]) -> [term()].
callback_args(before_model, [Config, Memory, Tools]) ->
    [project_config(Config), prune(Memory), prune(Tools)];
callback_args(after_model, [Config, Result]) ->
    [project_config(Config), maybe_failure(model, after_model, Result)];
callback_args(on_error, [Reason]) ->
    [adk_failure:sanitize(callback, on_error, Reason)];
callback_args(on_tool_end, [Name, Result]) ->
    [Name, maybe_failure(tool, on_tool_end, Result)];
callback_args(after_tool, [Name, Args, Context, Result]) ->
    [Name, prune(Args), prune(Context),
     maybe_failure(tool, after_tool, Result)];
callback_args(before_tool, [Name, Args, Context]) ->
    [Name, prune(Args), prune(Context)];
callback_args(_Hook, Args) ->
    Args.

-spec plugin_value(atom(), term()) -> term().
plugin_value(before_model, Value) -> model_request(Value);
plugin_value(on_model_error, Value) ->
    adk_failure:callback_value(plugin, on_model_error, Value);
plugin_value(on_tool_error, Value) ->
    adk_failure:callback_value(plugin, on_tool_error, Value);
plugin_value(on_agent_error, Value) ->
    adk_failure:callback_value(plugin, on_agent_error, Value);
plugin_value(on_run_error, Value) ->
    adk_failure:callback_value(plugin, on_run_error, Value);
plugin_value(on_error, Value) ->
    adk_failure:callback_value(plugin, on_error, Value);
plugin_value(before_tool, Value) -> prune(Value);
plugin_value(_Hook, Value) -> Value.

project_config(Config) when is_map(Config) ->
    Direct = maps:with(
               [provider, model, temperature, top_p, top_k,
                max_tokens, max_output_tokens, candidate_count,
                response_mime_type, thinking_config, safety_settings,
                builtin_tools, generation_config], Config),
    Direct0 = case maps:find(callback_config, Config) of
        {ok, CallbackConfig} when is_map(CallbackConfig) ->
            Direct#{callback_config => prune(CallbackConfig)};
        _ -> Direct
    end,
    Direct1 = project_nested_generation(Direct0),
    Direct2 = project_thinking(Direct1),
    project_safety(Direct2);
project_config(_) -> #{}.

project_nested_generation(Config) ->
    case maps:find(generation_config, Config) of
        {ok, Nested} when is_map(Nested) ->
            Config#{generation_config =>
                        maps:with(
                          [temperature, top_p, top_k, max_tokens,
                           max_output_tokens, candidate_count,
                           response_mime_type, thinking_config,
                           safety_settings], Nested)};
        {ok, _} -> maps:remove(generation_config, Config);
        error -> Config
    end.

project_thinking(Config) ->
    map_nested(Config, thinking_config,
               [thinking_level, thinking_budget,
                include_thoughts, include_thought_signatures]).

project_safety(Config) ->
    case maps:find(safety_settings, Config) of
        {ok, Settings} when is_list(Settings) ->
            Config#{safety_settings =>
                        [maps:with([category, threshold, method], Setting)
                         || Setting <- Settings, is_map(Setting)]};
        {ok, _} -> maps:remove(safety_settings, Config);
        error -> Config
    end.

map_nested(Config, Key, Allowed) ->
    case maps:find(Key, Config) of
        {ok, Value} when is_map(Value) ->
            Config#{Key => maps:with(Allowed, Value)};
        {ok, _} -> maps:remove(Key, Config);
        error -> Config
    end.

maybe_failure(Component, Operation, {error, _} = Error) ->
    adk_failure:callback_value(Component, Operation, Error);
maybe_failure(Component, Operation, {'EXIT', _} = Error) ->
    adk_failure:callback_value(Component, Operation, Error);
maybe_failure(_Component, _Operation, Result) -> Result.

prune(Map) when is_map(Map) ->
    maps:from_list(
      [{Key, prune(Value)} || {Key, Value} <- maps:to_list(Map),
                              not adk_context_guard:sensitive_key(Key),
                              not private_handle_key(Key)]);
prune(Tuple) when is_tuple(Tuple) ->
    list_to_tuple([prune(Value) || Value <- tuple_to_list(Tuple)]);
prune(List) when is_list(List) -> prune_list(List);
prune(Pid) when is_pid(Pid) -> undefined;
prune(Port) when is_port(Port) -> undefined;
prune(Ref) when is_reference(Ref) -> undefined;
prune(Fun) when is_function(Fun) -> undefined;
prune(Value) -> Value.

prune_list([]) -> [];
prune_list([Head | Tail]) -> [prune(Head) | prune_list_tail(Tail)].

prune_list_tail([]) -> [];
prune_list_tail([Head | Tail]) -> [prune(Head) | prune_list_tail(Tail)];
prune_list_tail(_Improper) -> undefined.

private_handle_key(Key) ->
    case normalized_key(Key) of
        <<"pid">> -> true;
        <<"ref">> -> true;
        <<"handle">> -> true;
        <<"client">> -> true;
        <<"connection">> -> true;
        Normalized when is_binary(Normalized) ->
            has_suffix(Normalized, <<"pid">>) orelse
            has_suffix(Normalized, <<"ref">>) orelse
            has_suffix(Normalized, <<"handle">>) orelse
            has_suffix(Normalized, <<"client">>) orelse
            has_suffix(Normalized, <<"connection">>);
        _ -> false
    end.

normalized_key(Key) when is_atom(Key) ->
    normalized_key(atom_to_binary(Key, utf8));
normalized_key(Key) when is_list(Key) ->
    try normalized_key(unicode:characters_to_binary(Key))
    catch _:_ -> undefined
    end;
normalized_key(Key) when is_binary(Key) ->
    try
        Lower = string:lowercase(Key),
        lists:foldl(
          fun(Separator, Acc) ->
              binary:replace(Acc, Separator, <<>>, [global])
          end, Lower, [<<"_">>, <<"-">>, <<" ">>, <<".">>, <<":">>])
    catch _:_ -> undefined
    end;
normalized_key(_) -> undefined.

has_suffix(Binary, Suffix) when byte_size(Binary) >= byte_size(Suffix) ->
    Offset = byte_size(Binary) - byte_size(Suffix),
    binary:part(Binary, Offset, byte_size(Suffix)) =:= Suffix;
has_suffix(_, _) -> false.

copy_instruction_source(Key, Source, Acc) ->
    case maps:find(Key, Source) of
        {ok, Value} ->
            case safe_instruction_source(Value) of
                true -> Acc#{Key => Value};
                false -> Acc
            end;
        error -> Acc
    end.

safe_instruction_source(Value) when is_binary(Value) -> true;
safe_instruction_source(Value) when is_list(Value) ->
    try is_binary(unicode:characters_to_binary(Value))
    catch _:_ -> false
    end;
safe_instruction_source({dynamic, Module, Function}) ->
    is_atom(Module) andalso is_atom(Function);
safe_instruction_source(undefined) -> true;
safe_instruction_source(_) -> false.
