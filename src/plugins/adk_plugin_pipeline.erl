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
-define(DEFAULT_MAX_RESULT_BYTES, 262144).
-define(MAX_RESULT_DEPTH, 64).
-define(MAX_PLUGINS, 128).
-define(MAX_PLUGIN_ID_BYTES, 256).
-define(MAX_TIMEOUT_MS, 120000).
-define(MAX_HEAP_WORDS, 10000000).
-define(MAX_RESULT_BYTES, 1048576).
-define(MAX_CONFIG_BYTES, 1048576).

-opaque pipeline() :: #{version := pos_integer(),
                        defaults := map(),
                        plugins := [map()]}.
-type trace_entry() :: map().
-type outcome() ::
    {continue, term(), [trace_entry()]} |
    {amend, term(), [trace_entry()]} |
    {return, term(), [trace_entry()]} |
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
compile(Plugins, Defaults) when is_map(Defaults) ->
    %% Do not call is_list/1 before the recursive cap: proving that a hostile
    %% proper list is proper would itself traverse beyond MAX_PLUGINS.
    case Plugins of
        [] -> compile_bounded_input(Plugins, Defaults);
        [_ | _] -> compile_bounded_input(Plugins, Defaults);
        _ -> {error, invalid_plugin_pipeline}
    end;
compile(_Plugins, _Defaults) ->
    {error, invalid_plugin_pipeline}.

compile_bounded_input(Plugins, Defaults) ->
    case compile_defaults(Defaults) of
        {ok, CompiledDefaults} ->
            compile_plugins(Plugins, CompiledDefaults, 0, [], #{});
        {error, _} = Error -> Error
    end.

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
                    run_plugins(Plugins, Hook, Context, PublicValue,
                                continue, []);
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
             <<"max_heap_words">> => maps:get(max_heap_words, Plugin),
             <<"max_result_bytes">> => maps:get(max_result_bytes, Plugin)}
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
        max_result_bytes => maps:get(max_result_bytes, Defaults,
                                     ?DEFAULT_MAX_RESULT_BYTES),
        config => #{}
    },
    validate_common(Descriptor).

compile_plugins([], Defaults, _Index, Acc, _Ids) ->
    {ok, #{version => ?VERSION,
           defaults => maps:without([config], Defaults),
           plugins => lists:reverse(Acc)}};
compile_plugins([_ | _], _Defaults, Index, _Acc, _Ids)
  when Index >= ?MAX_PLUGINS ->
    {error, {plugin_limit, ?MAX_PLUGINS}};
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
        max_result_bytes => maps:get(max_result_bytes, Descriptor,
                                     maps:get(max_result_bytes, Defaults)),
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
  when is_binary(Id), byte_size(Id) > 0,
       byte_size(Id) =< ?MAX_PLUGIN_ID_BYTES, is_atom(Module) ->
    case maps:is_key(Id, Ids) of
        true -> {error, {duplicate_plugin_id, Id}};
        false -> {ok, Ids#{Id => true}}
    end;
validate_identity(Id, _Module, Index, _Ids)
  when not is_binary(Id) ->
    {error, {invalid_plugin_descriptor, Index, invalid_id}};
validate_identity(Id, _Module, Index, _Ids)
  when Id =:= <<>>; byte_size(Id) > ?MAX_PLUGIN_ID_BYTES ->
    {error, {invalid_plugin_descriptor, Index, invalid_id}};
validate_identity(_Id, _Module, Index, _Ids) ->
    {error, {invalid_plugin_descriptor, Index, invalid_module}}.

validate_common(Common) ->
    Mode = maps:get(mode, Common),
    Failure = maps:get(failure_policy, Common),
    Timeout = maps:get(timeout_ms, Common),
    Heap = maps:get(max_heap_words, Common),
    ResultBytes = maps:get(max_result_bytes, Common),
    Config = maps:get(config, Common),
    case {valid_mode(Mode), valid_failure_policy(Failure),
          is_integer(Timeout) andalso Timeout > 0
              andalso Timeout =< ?MAX_TIMEOUT_MS,
          is_integer(Heap) andalso Heap >= 1000
              andalso Heap =< ?MAX_HEAP_WORDS,
          is_integer(ResultBytes) andalso ResultBytes > 0
              andalso ResultBytes =< ?MAX_RESULT_BYTES,
          valid_plugin_config(Config)} of
        {true, true, true, true, true, true} -> {ok, Common};
        {false, _, _, _, _, _} -> {error, {invalid_mode, Mode}};
        {_, false, _, _, _, _} ->
            {error, {invalid_failure_policy, Failure}};
        {_, _, false, _, _, _} -> {error, {invalid_timeout_ms, Timeout}};
        {_, _, _, false, _, _} -> {error, {invalid_max_heap_words, Heap}};
        {_, _, _, _, false, _} ->
            {error, {invalid_max_result_bytes, ResultBytes}};
        {_, _, _, _, _, false} -> {error, invalid_plugin_config}
    end.

valid_mode(observe) -> true;
valid_mode(intervene) -> true;
valid_mode(_) -> false.

valid_failure_policy(open) -> true;
valid_failure_policy(closed) -> true;
valid_failure_policy(_) -> false.

valid_plugin_config(Config) when is_map(Config) ->
    try erlang:external_size(Config) of
        Size -> Size =< ?MAX_CONFIG_BYTES
    catch
        _:_ -> false
    end;
valid_plugin_config(_Config) -> false.

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

run_plugins([], _Hook, _Context, Value, Disposition, Trace) ->
    {Disposition, Value, lists:reverse(Trace)};
run_plugins([Plugin | Rest], Hook, Context, Value0, Disposition, Trace0) ->
    case invoke_plugin(Plugin, Hook, Context, Value0) of
        not_implemented ->
            Entry = trace(Plugin, Hook, skipped),
            run_plugins(Rest, Hook, Context, Value0, Disposition,
                        [Entry | Trace0]);
        {ok, Result} ->
            apply_result(Plugin, Rest, Hook, Context, Value0,
                         Result, Disposition, Trace0);
        {failure, Failure} ->
            Entry = trace(Plugin, Hook, Failure),
            case notification_hook(Hook) orelse
                 maps:get(failure_policy, Plugin) =:= open of
                true ->
                    run_plugins(Rest, Hook, Context, Value0, Disposition,
                                [Entry | Trace0]);
                false ->
                    Reason = {plugin_failed, maps:get(id, Plugin), Hook,
                              Failure},
                    {error, Reason, lists:reverse([Entry | Trace0])}
            end
    end.

apply_result(Plugin, Rest, Hook, Context, Value, Result,
             Disposition, Trace0) ->
    case notification_hook(Hook) of
        true ->
            apply_notification_result(
              Plugin, Rest, Hook, Context, Value, Result,
              Disposition, Trace0);
        false ->
            apply_intervention_result(
              Plugin, Rest, Hook, Context, Value, Result,
              Disposition, Trace0)
    end.

apply_notification_result(Plugin, Rest, Hook, Context, Value, Result,
                          Disposition, Trace0) ->
    Outcome = case Result of
        observe -> observed;
        continue -> observed;
        ok -> observed;
        _ -> notification_result_ignored
    end,
    continue_with(Plugin, Rest, Hook, Context, Value, Disposition,
                  Outcome, Trace0).

apply_intervention_result(Plugin, Rest, Hook, Context, Value, Result,
                          Disposition, Trace0) ->
    Mode = maps:get(mode, Plugin),
    case {Mode, Result} of
        {_, observe} ->
            continue_with(Plugin, Rest, Hook, Context, Value,
                          Disposition, observed, Trace0);
        {_, continue} ->
            continue_with(Plugin, Rest, Hook, Context, Value,
                          Disposition, observed, Trace0);
        {_, ok} ->
            continue_with(Plugin, Rest, Hook, Context, Value,
                          Disposition, observed, Trace0);
        {intervene, {amend, Amendment}} ->
            continue_with(Plugin, Rest, Hook, Context, Amendment,
                          amend, amended, Trace0);
        {intervene, {return, Returned}} ->
            Entry = trace(Plugin, Hook, returned),
            {return, Returned, lists:reverse([Entry | Trace0])};
        %% Compatibility is deliberately an early return. Treating replace as
        %% an amendment was ambiguous and let later callbacks observe a value
        %% after the operation should already have short-circuited.
        {intervene, {replace, Returned}} ->
            Entry = trace(Plugin, Hook, returned),
            {return, Returned, lists:reverse([Entry | Trace0])};
        {intervene, {halt, Reason}} ->
            Entry = trace(Plugin, Hook, halted),
            {halt, adk_secret_redactor:redact(Reason),
             lists:reverse([Entry | Trace0])};
        {observe, {amend, _}} ->
            plugin_contract_failure(
              Plugin, Rest, Hook, Context, Value, Disposition,
              observer_cannot_amend, Trace0);
        {observe, {return, _}} ->
            plugin_contract_failure(
              Plugin, Rest, Hook, Context, Value, Disposition,
              observer_cannot_return, Trace0);
        {observe, {replace, _}} ->
            plugin_contract_failure(
              Plugin, Rest, Hook, Context, Value, Disposition,
              observer_cannot_return, Trace0);
        {observe, {halt, _}} ->
            plugin_contract_failure(
              Plugin, Rest, Hook, Context, Value, Disposition,
              observer_cannot_halt, Trace0);
        _ ->
            plugin_contract_failure(
              Plugin, Rest, Hook, Context, Value, Disposition,
              invalid_result, Trace0)
    end.

continue_with(Plugin, Rest, Hook, Context, Value, Disposition,
              Outcome, Trace0) ->
    Entry = trace(Plugin, Hook, Outcome),
    run_plugins(Rest, Hook, Context, Value, Disposition, [Entry | Trace0]).

plugin_contract_failure(Plugin, Rest, Hook, Context, Value, Disposition,
                        Failure, Trace0) ->
    Entry = trace(Plugin, Hook, Failure),
    case maps:get(failure_policy, Plugin) of
                open ->
            run_plugins(Rest, Hook, Context, Value, Disposition,
                                [Entry | Trace0]);
                closed ->
            {error, {plugin_failed, maps:get(id, Plugin), Hook, Failure},
             lists:reverse([Entry | Trace0])}
    end.

invoke_plugin(Plugin, Hook, Context, Value) ->
    Module = maps:get(module, Plugin),
    case callback_hook(Module, Hook) of
        none -> not_implemented;
        CallbackHook ->
            Owner = self(),
            ReplyRef = make_ref(),
            ReplyAlias = erlang:alias([reply]),
            Deadline = erlang:monotonic_time(millisecond) +
                       maps:get(timeout_ms, Plugin),
            ControllerFun = fun() ->
                plugin_controller(Owner, ReplyAlias, ReplyRef, Module,
                                  CallbackHook, Context, Value, Plugin)
            end,
            {Controller, Monitor} = spawn_monitor(ControllerFun),
            receive_plugin(Controller, Monitor, ReplyAlias, ReplyRef,
                           Deadline)
    end.

callback_hook(Module, Hook) ->
    case erlang:function_exported(Module, Hook, 3) of
        true -> Hook;
        false when Hook =:= on_agent_error; Hook =:= on_run_error ->
            case erlang:function_exported(Module, on_error, 3) of
                true -> on_error;
                false -> none
            end;
        false -> none
    end.

plugin_controller(Owner, ReplyAlias, ReplyRef, Module, Hook,
                  Context, Value, Plugin) ->
    process_flag(trap_exit, true),
    OwnerMonitor = erlang:monitor(process, Owner),
    Controller = self(),
    Config = maps:get(config, Plugin),
    MaxResultBytes = maps:get(max_result_bytes, Plugin),
    Worker = fun() ->
        WorkerResult = try erlang:apply(Module, Hook,
                                        [Context, Value, Config]) of
            CallbackResult ->
                bound_callback_result(CallbackResult, MaxResultBytes)
        catch
            _Class:_Reason -> callback_exception
        end,
        CompletedAt = erlang:monotonic_time(millisecond),
        Controller ! {adk_plugin_worker_result, self(), CompletedAt,
                      WorkerResult}
    end,
    SpawnOpts = [link, monitor, {message_queue_data, off_heap},
                 {max_heap_size,
                  #{size => maps:get(max_heap_words, Plugin),
                    kill => true,
                    error_logger => false,
                    include_shared_binaries => true}}],
    {WorkerPid, WorkerMonitor} = spawn_opt(Worker, SpawnOpts),
    plugin_controller_loop(OwnerMonitor, WorkerPid, WorkerMonitor,
                           ReplyAlias, ReplyRef, undefined).

plugin_controller_loop(OwnerMonitor, WorkerPid, WorkerMonitor,
                       ReplyAlias, ReplyRef, Completion) ->
    receive
        {adk_plugin_worker_result, WorkerPid, CompletedAt, Result}
          when Completion =:= undefined ->
            plugin_controller_loop(
              OwnerMonitor, WorkerPid, WorkerMonitor,
              ReplyAlias, ReplyRef, {CompletedAt, Result});
        {'DOWN', WorkerMonitor, process, WorkerPid, Reason} ->
            _ = erlang:demonitor(OwnerMonitor, [flush]),
            Reply = case Completion of
                {CompletedAt, Result} ->
                    {adk_plugin_reply, ReplyRef, CompletedAt, Result};
                undefined ->
                    {adk_plugin_reply, ReplyRef,
                     erlang:monotonic_time(millisecond),
                     {callback_failure, worker_down}}
            end,
            ReplyAlias ! Reply,
            case Reason of
                _ -> ok
            end;
        {'DOWN', OwnerMonitor, process, _Owner, _Reason} ->
            exit(WorkerPid, kill),
            receive
                {'DOWN', WorkerMonitor, process, WorkerPid, _} -> ok
            after 100 -> ok
            end;
        {'EXIT', WorkerPid, _Reason} ->
            plugin_controller_loop(
              OwnerMonitor, WorkerPid, WorkerMonitor,
              ReplyAlias, ReplyRef, Completion)
    end.

bound_callback_result(Result, MaxBytes) ->
    case bounded_result_shape(Result) of
        invalid -> {callback_result, invalid_callback_result};
        {valid, Payload} ->
            case safe_result_term(Payload, ?MAX_RESULT_DEPTH) of
                false -> {callback_failure, invalid_result_type};
                true ->
                    try erlang:external_size(Result) of
                        Size when Size =< MaxBytes ->
                            {callback_result, Result};
                        _ -> {callback_failure, result_too_large}
                    catch
                        _:_ -> {callback_failure, invalid_result_type}
                    end
            end
    end.

bounded_result_shape(observe) -> {valid, observe};
bounded_result_shape(continue) -> {valid, continue};
bounded_result_shape(ok) -> {valid, ok};
bounded_result_shape({amend, Payload}) -> {valid, Payload};
bounded_result_shape({return, Payload}) -> {valid, Payload};
bounded_result_shape({replace, Payload}) -> {valid, Payload};
bounded_result_shape({halt, Payload}) -> {valid, Payload};
bounded_result_shape(_) -> invalid.

safe_result_term(_Value, Depth) when Depth < 0 -> false;
safe_result_term(Value, _Depth)
  when is_atom(Value); is_binary(Value); is_integer(Value);
       is_float(Value) -> true;
safe_result_term(Value, Depth) when is_tuple(Value) ->
    safe_result_list(tuple_to_list(Value), Depth - 1);
safe_result_term(Value, Depth) when is_map(Value) ->
    safe_result_list(maps:to_list(Value), Depth - 1);
safe_result_term(Value, Depth) when is_list(Value) ->
    safe_result_list(Value, Depth - 1);
safe_result_term(_Value, _Depth) -> false.

safe_result_list([], _Depth) -> true;
safe_result_list([Value | Rest], Depth) ->
    safe_result_term(Value, Depth) andalso safe_result_list(Rest, Depth);
safe_result_list(_Improper, _Depth) -> false.

receive_plugin(Controller, Monitor, ReplyAlias, ReplyRef, Deadline) ->
    Remaining = erlang:max(
                  0, Deadline - erlang:monotonic_time(millisecond)),
    receive
        {adk_plugin_reply, ReplyRef, CompletedAt,
         {callback_result, Result}} ->
            erlang:demonitor(Monitor, [flush]),
            _ = erlang:unalias(ReplyAlias),
            case CompletedAt =< Deadline of
                true -> {ok, Result};
                false -> {failure, timeout}
            end;
        {adk_plugin_reply, ReplyRef, _CompletedAt, callback_exception} ->
            erlang:demonitor(Monitor, [flush]),
            _ = erlang:unalias(ReplyAlias),
            {failure, exception};
        {adk_plugin_reply, ReplyRef, _CompletedAt,
         {callback_failure, Failure}} ->
            erlang:demonitor(Monitor, [flush]),
            _ = erlang:unalias(ReplyAlias),
            {failure, Failure};
        {'DOWN', Monitor, process, Controller, _Reason} ->
            flush_reply(ReplyRef),
            _ = erlang:unalias(ReplyAlias),
            {failure, worker_down}
    after Remaining ->
        exit(Controller, kill),
        receive
            {'DOWN', Monitor, process, Controller, _} -> ok
        after 100 -> erlang:demonitor(Monitor, [flush])
        end,
        _ = erlang:unalias(ReplyAlias),
        flush_reply(ReplyRef),
        {failure, timeout}
    end.

flush_reply(ReplyRef) ->
    receive
        {adk_plugin_reply, ReplyRef, _, _} -> ok
    after 0 -> ok
    end.

notification_hook(after_run) -> true;
notification_hook(on_agent_error) -> true;
notification_hook(on_run_error) -> true;
notification_hook(_) -> false.

trace(Plugin, Hook, Outcome) ->
    #{<<"plugin_id">> => maps:get(id, Plugin),
      <<"hook">> => atom_to_binary(Hook, utf8),
      <<"mode">> => atom_to_binary(maps:get(mode, Plugin), utf8),
      <<"outcome">> => atom_to_binary(Outcome, utf8)}.

-spec reason_tag(adk_json:error_reason()) -> atom().
reason_tag({Tag, _}) -> Tag;
reason_tag({Tag, _, _}) -> Tag.

safe_hook(Hook) when is_atom(Hook) -> Hook;
safe_hook(_) -> invalid_hook.
