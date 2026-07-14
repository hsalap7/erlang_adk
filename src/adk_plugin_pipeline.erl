%% @doc Compiled, ordered execution pipeline for Runner-global plugins.
%%
%% Pipelines are immutable values and therefore cheap to keep in a Runner.
%% Each callback executes in its own monitored lightweight process with a
%% deadline and maximum heap. A callback can never block or exhaust the
%% invocation process indefinitely.
-module(adk_plugin_pipeline).

-export([compile/1, compile/2, run/4, describe/1]).

-define(VERSION, 1).
-define(DEFAULT_TIMEOUT_MS, 1000).
-define(DEFAULT_MAX_HEAP_WORDS, 250000).

-opaque pipeline() :: #{version := pos_integer(),
                        defaults := map(),
                        plugins := [map()]}.
-type trace_entry() :: map().
-type outcome() ::
    {ok, term(), [trace_entry()]} |
    {halt, term(), [trace_entry()]} |
    {error, term(), [trace_entry()]}.
-export_type([pipeline/0, outcome/0]).

%% @doc Compile plugin descriptors in strict list order.
%%
%% A descriptor has a binary `id', an already-existing module atom, and may
%% set `mode' (`observe' or `intervene'), `failure_policy' (`open' or
%% `closed'), `timeout_ms', `max_heap_words', and `config'. No string or binary
%% is ever converted to a module atom.
-spec compile([map()]) -> {ok, pipeline()} | {error, term()}.
compile(Plugins) ->
    compile(Plugins, #{}).

-spec compile([map()], map()) -> {ok, pipeline()} | {error, term()}.
compile(Plugins, Defaults) when is_list(Plugins), is_map(Defaults) ->
    case compile_defaults(Defaults) of
        {ok, CompiledDefaults} ->
            compile_plugins(Plugins, CompiledDefaults, 0, [], #{});
        {error, _} = Error -> Error
    end;
compile(_Plugins, _Defaults) ->
    {error, invalid_plugin_pipeline}.

%% @doc Run one lifecycle hook through every configured plugin.
%%
%% The trace contains only bounded structural status, never callback values or
%% exception text. Fail-open failures are recorded and execution continues;
%% fail-closed failures stop with a typed, secret-free error.
-spec run(pipeline(), adk_plugin:hook(), map(), term()) -> outcome().
run(#{version := ?VERSION, plugins := Plugins}, Hook, Context0, Value)
  when is_map(Context0) ->
    case adk_plugin:is_hook(Hook) of
        true ->
            case adk_context_guard:sanitize_value(Context0) of
                {ok, Context} when is_map(Context) ->
                    PublicValue = adk_callback_view:plugin_value(Hook, Value),
                    run_plugins(Plugins, Hook, Context, PublicValue, []);
                {ok, _} ->
                    {error, invalid_plugin_context, []};
                {error, Reason} ->
                    {error, {invalid_plugin_context, reason_tag(Reason)}, []}
            end;
        false ->
            {error, {unknown_plugin_hook, Hook}, []}
    end;
run(_Pipeline, Hook, _Context, _Value) ->
    {error, {invalid_plugin_pipeline_or_context, safe_hook(Hook)}, []}.

%% @doc Return JSON-safe configuration metadata without module configuration.
-spec describe(pipeline()) -> map().
describe(#{version := ?VERSION, plugins := Plugins}) ->
    #{<<"schema_version">> => ?VERSION,
      <<"plugins">> =>
          [#{<<"id">> => maps:get(id, Plugin),
             <<"mode">> => atom_to_binary(maps:get(mode, Plugin), utf8),
             <<"failure_policy">> =>
                 atom_to_binary(maps:get(failure_policy, Plugin), utf8),
             <<"timeout_ms">> => maps:get(timeout_ms, Plugin),
             <<"max_heap_words">> => maps:get(max_heap_words, Plugin)}
           || Plugin <- Plugins]};
describe(_) ->
    #{<<"schema_version">> => ?VERSION, <<"plugins">> => []}.

compile_defaults(Defaults) ->
    Descriptor = #{
        mode => maps:get(mode, Defaults, observe),
        failure_policy => maps:get(failure_policy, Defaults, open),
        timeout_ms => maps:get(timeout_ms, Defaults, ?DEFAULT_TIMEOUT_MS),
        max_heap_words => maps:get(max_heap_words, Defaults,
                                   ?DEFAULT_MAX_HEAP_WORDS),
        config => #{}
    },
    validate_common(Descriptor).

compile_plugins([], Defaults, _Index, Acc, _Ids) ->
    {ok, #{version => ?VERSION,
           defaults => maps:without([config], Defaults),
           plugins => lists:reverse(Acc)}};
compile_plugins([Descriptor | Rest], Defaults, Index, Acc, Ids)
  when is_map(Descriptor) ->
    case compile_plugin(Descriptor, Defaults, Index, Ids) of
        {ok, Plugin, NewIds} ->
            compile_plugins(Rest, Defaults, Index + 1,
                            [Plugin | Acc], NewIds);
        {error, _} = Error -> Error
    end;
compile_plugins([_ | _], _Defaults, Index, _Acc, _Ids) ->
    {error, {invalid_plugin_descriptor, Index, expected_map}};
compile_plugins(_Improper, _Defaults, Index, _Acc, _Ids) ->
    {error, {invalid_plugin_list, Index}}.

compile_plugin(Descriptor, Defaults, Index, Ids) ->
    Id = maps:get(id, Descriptor, undefined),
    Module = maps:get(module, Descriptor, undefined),
    Common0 = Defaults#{
        mode => maps:get(mode, Descriptor, maps:get(mode, Defaults)),
        failure_policy => maps:get(failure_policy, Descriptor,
                                   maps:get(failure_policy, Defaults)),
        timeout_ms => maps:get(timeout_ms, Descriptor,
                               maps:get(timeout_ms, Defaults)),
        max_heap_words => maps:get(max_heap_words, Descriptor,
                                   maps:get(max_heap_words, Defaults)),
        config => maps:get(config, Descriptor, #{})
    },
    case validate_identity(Id, Module, Index, Ids) of
        {ok, NewIds} ->
            case validate_common(Common0) of
                {ok, Common} ->
                    case validate_module(Module) of
                        ok ->
                            {ok, Common#{id => Id, module => Module,
                                        index => Index}, NewIds};
                        {error, Reason} ->
                            {error, {invalid_plugin_descriptor, Index, Reason}}
                    end;
                {error, Reason} ->
                    {error, {invalid_plugin_descriptor, Index, Reason}}
            end;
        {error, _} = Error -> Error
    end.

validate_identity(Id, Module, _Index, Ids)
  when is_binary(Id), byte_size(Id) > 0, is_atom(Module) ->
    case maps:is_key(Id, Ids) of
        true -> {error, {duplicate_plugin_id, Id}};
        false -> {ok, Ids#{Id => true}}
    end;
validate_identity(Id, _Module, Index, _Ids)
  when not is_binary(Id); Id =:= <<>> ->
    {error, {invalid_plugin_descriptor, Index, invalid_id}};
validate_identity(_Id, _Module, Index, _Ids) ->
    {error, {invalid_plugin_descriptor, Index, invalid_module}}.

validate_common(Common) ->
    Mode = maps:get(mode, Common),
    Failure = maps:get(failure_policy, Common),
    Timeout = maps:get(timeout_ms, Common),
    Heap = maps:get(max_heap_words, Common),
    Config = maps:get(config, Common),
    case {valid_mode(Mode), valid_failure_policy(Failure),
          is_integer(Timeout) andalso Timeout > 0,
          is_integer(Heap) andalso Heap >= 1000,
          is_map(Config)} of
        {true, true, true, true, true} -> {ok, Common};
        {false, _, _, _, _} -> {error, {invalid_mode, Mode}};
        {_, false, _, _, _} -> {error, {invalid_failure_policy, Failure}};
        {_, _, false, _, _} -> {error, {invalid_timeout_ms, Timeout}};
        {_, _, _, false, _} -> {error, {invalid_max_heap_words, Heap}};
        {_, _, _, _, false} -> {error, invalid_plugin_config}
    end.

valid_mode(observe) -> true;
valid_mode(intervene) -> true;
valid_mode(_) -> false.

valid_failure_policy(open) -> true;
valid_failure_policy(closed) -> true;
valid_failure_policy(_) -> false.

validate_module(Module) ->
    case code:ensure_loaded(Module) of
        {module, Module} ->
            case lists:any(
                   fun(Hook) -> erlang:function_exported(Module, Hook, 3) end,
                   adk_plugin:hooks()) of
                true -> ok;
                false -> {error, no_plugin_callbacks}
            end;
        {error, _} -> {error, plugin_module_unavailable}
    end.

run_plugins([], _Hook, _Context, Value, Trace) ->
    {ok, Value, lists:reverse(Trace)};
run_plugins([Plugin | Rest], Hook, Context, Value0, Trace0) ->
    case invoke_plugin(Plugin, Hook, Context, Value0) of
        not_implemented ->
            Entry = trace(Plugin, Hook, skipped),
            run_plugins(Rest, Hook, Context, Value0, [Entry | Trace0]);
        {ok, Result} ->
            apply_result(Plugin, Rest, Hook, Context, Value0,
                         Result, Trace0);
        {failure, Failure} ->
            Entry = trace(Plugin, Hook, Failure),
            case maps:get(failure_policy, Plugin) of
                open ->
                    run_plugins(Rest, Hook, Context, Value0,
                                [Entry | Trace0]);
                closed ->
                    Reason = {plugin_failed, maps:get(id, Plugin), Hook,
                              Failure},
                    {error, Reason, lists:reverse([Entry | Trace0])}
            end
    end.

apply_result(Plugin, Rest, Hook, Context, Value, Result, Trace0) ->
    Mode = maps:get(mode, Plugin),
    case {Mode, Result} of
        {_, observe} ->
            continue_with(Plugin, Rest, Hook, Context, Value,
                          observed, Trace0);
        {_, continue} ->
            continue_with(Plugin, Rest, Hook, Context, Value,
                          observed, Trace0);
        {_, ok} ->
            continue_with(Plugin, Rest, Hook, Context, Value,
                          observed, Trace0);
        {intervene, {replace, Replacement}} ->
            continue_with(Plugin, Rest, Hook, Context, Replacement,
                          replaced, Trace0);
        {intervene, {halt, Reason}} ->
            Entry = trace(Plugin, Hook, halted),
            {halt, adk_secret_redactor:redact(Reason),
             lists:reverse([Entry | Trace0])};
        {observe, {replace, _}} ->
            plugin_contract_failure(Plugin, Rest, Hook, Context, Value,
                                    observer_cannot_replace, Trace0);
        {observe, {halt, _}} ->
            plugin_contract_failure(Plugin, Rest, Hook, Context, Value,
                                    observer_cannot_halt, Trace0);
        _ ->
            plugin_contract_failure(Plugin, Rest, Hook, Context, Value,
                                    invalid_result, Trace0)
    end.

continue_with(Plugin, Rest, Hook, Context, Value, Outcome, Trace0) ->
    Entry = trace(Plugin, Hook, Outcome),
    run_plugins(Rest, Hook, Context, Value, [Entry | Trace0]).

plugin_contract_failure(Plugin, Rest, Hook, Context, Value,
                        Failure, Trace0) ->
    Entry = trace(Plugin, Hook, Failure),
    case maps:get(failure_policy, Plugin) of
        open -> run_plugins(Rest, Hook, Context, Value, [Entry | Trace0]);
        closed ->
            {error, {plugin_failed, maps:get(id, Plugin), Hook, Failure},
             lists:reverse([Entry | Trace0])}
    end.

invoke_plugin(Plugin, Hook, Context, Value) ->
    Module = maps:get(module, Plugin),
    case erlang:function_exported(Module, Hook, 3) of
        false -> not_implemented;
        true ->
            Parent = self(),
            ReplyRef = make_ref(),
            Config = maps:get(config, Plugin),
            Worker = fun() ->
                Result = try erlang:apply(Module, Hook,
                                          [Context, Value, Config]) of
                    CallbackResult -> {callback_result, CallbackResult}
                catch
                    _Class:_Reason -> callback_exception
                end,
                Parent ! {adk_plugin_reply, ReplyRef, self(), Result}
            end,
            SpawnOpts = [monitor,
                         {max_heap_size,
                          #{size => maps:get(max_heap_words, Plugin),
                            kill => true,
                            error_logger => false}}],
            {Pid, Monitor} = spawn_opt(Worker, SpawnOpts),
            receive_plugin(Pid, Monitor, ReplyRef,
                           maps:get(timeout_ms, Plugin))
    end.

receive_plugin(Pid, Monitor, ReplyRef, Timeout) ->
    receive
        {adk_plugin_reply, ReplyRef, Pid, {callback_result, Result}} ->
            erlang:demonitor(Monitor, [flush]),
            {ok, Result};
        {adk_plugin_reply, ReplyRef, Pid, callback_exception} ->
            erlang:demonitor(Monitor, [flush]),
            {failure, exception};
        {'DOWN', Monitor, process, Pid, _Reason} ->
            flush_reply(ReplyRef, Pid),
            {failure, worker_down}
    after Timeout ->
        exit(Pid, kill),
        receive
            {'DOWN', Monitor, process, Pid, _} -> ok
        after 100 -> erlang:demonitor(Monitor, [flush])
        end,
        flush_reply(ReplyRef, Pid),
        {failure, timeout}
    end.

flush_reply(ReplyRef, Pid) ->
    receive
        {adk_plugin_reply, ReplyRef, Pid, _} -> ok
    after 0 -> ok
    end.

trace(Plugin, Hook, Outcome) ->
    #{<<"plugin_id">> => maps:get(id, Plugin),
      <<"hook">> => atom_to_binary(Hook, utf8),
      <<"mode">> => atom_to_binary(maps:get(mode, Plugin), utf8),
      <<"outcome">> => atom_to_binary(Outcome, utf8)}.

reason_tag({Tag, _}) when is_atom(Tag) -> Tag;
reason_tag({Tag, _, _}) when is_atom(Tag) -> Tag.

safe_hook(Hook) when is_atom(Hook) -> Hook;
safe_hook(_) -> invalid_hook.
