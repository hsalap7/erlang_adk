%% @doc Bounded synchronous orphan-reconciliation pass.
-module(adk_artifact_orphan_reconciler).

-export([run/3]).

run(Journal, {Module, HandlerState}, Options)
  when is_atom(Module), is_map(Options) ->
    case compile_options(Options) of
        {ok, Limits} ->
            reconcile_loop(Journal, Module, HandlerState, Limits,
                           maps:get(max_items, Limits), 0, 0);
        {error, _} = Error -> Error
    end;
run(_, _, _) -> {error, invalid_artifact_reconciler_request}.

compile_options(Options) ->
    Defaults = #{max_items => 100, lease_ms => 15000,
                 call_timeout_ms => 5000,
                 now_ms => erlang:system_time(millisecond)},
    Unknown = lists:sort(maps:keys(maps:without(maps:keys(Defaults), Options))),
    Full = maps:merge(Defaults, Options),
    case {Unknown,
          integer_in(maps:get(max_items, Full), 1, 10000),
          integer_in(maps:get(lease_ms, Full), 250, 3600000),
          integer_in(maps:get(call_timeout_ms, Full), 10, 600000),
          is_integer(maps:get(now_ms, Full)),
          maps:get(lease_ms, Full) > maps:get(call_timeout_ms, Full)} of
        {[], true, true, true, true, true} -> {ok, Full};
        {[_ | _], _, _, _, _, _} ->
            {error, {invalid_artifact_reconciler_options,
                     {unknown_keys, Unknown}}};
        _ -> {error, invalid_artifact_reconciler_options}
    end.

reconcile_loop(_Journal, _Module, _State, _Limits, 0, Done, Failed) ->
    {ok, #{processed => Done, failed => Failed}};
reconcile_loop(Journal, Module, HandlerState, Limits, Remaining,
               Done, Failed) ->
    Owner = crypto:strong_rand_bytes(24),
    Now = maps:get(now_ms, Limits),
    case adk_artifact_effect_journal:claim_orphan(
           Journal, Owner, Now, maps:get(lease_ms, Limits)) of
        none -> {ok, #{processed => Done, failed => Failed}};
        {ok, Work} ->
            Result = invoke(Module, HandlerState, Work,
                            maps:get(call_timeout_ms, Limits)),
            EffectId = maps:get(effect_id, Work),
            case Result of
                {ok, Outcome} ->
                    case adk_artifact_effect_journal:resolve(
                           Journal, EffectId, Owner, Outcome, Now + 1) of
                        {ok, _} ->
                            reconcile_loop(
                              Journal, Module, HandlerState, Limits,
                              Remaining - 1, Done + 1, Failed);
                        {error, _} ->
                            {error, artifact_reconciliation_journal_unavailable}
                    end;
                {error, Reason} ->
                    case adk_artifact_effect_journal:retry(
                           Journal, EffectId, Owner, Reason, Now + 1) of
                        {ok, _} ->
                            reconcile_loop(
                              Journal, Module, HandlerState, Limits,
                              Remaining - 1, Done + 1, Failed + 1);
                        {error, _} ->
                            {error, artifact_reconciliation_journal_unavailable}
                    end
            end;
        {error, _} = Error -> Error
    end.

invoke(Module, State, Work, Timeout) ->
    case code:ensure_loaded(Module) of
        {module, Module} ->
            case erlang:function_exported(Module, reconcile, 3) of
                true -> invoke_loaded(Module, State, Work, Timeout);
                false -> {error, artifact_reconcile_callback_missing}
            end;
        {error, _} -> {error, artifact_reconcile_handler_unavailable}
    end.

invoke_loaded(Module, State, Work, Timeout) ->
    Parent = self(), Ref = make_ref(),
    {Pid, Monitor} = spawn_monitor(fun() ->
        Reply = try Module:reconcile(State, Work, Timeout) of
            Value -> Value
        catch _:_ -> {error, artifact_reconcile_callback_failed}
        end,
        Parent ! {Ref, self(), Reply}
    end),
    receive
        {Ref, Pid, {ok, Outcome}} when Outcome =:= committed;
                                      Outcome =:= compensated;
                                      Outcome =:= not_applied ->
            erlang:demonitor(Monitor, [flush]),
            {ok, Outcome};
        {Ref, Pid, {error, Reason}} ->
            erlang:demonitor(Monitor, [flush]), {error, Reason};
        {Ref, Pid, _} ->
            erlang:demonitor(Monitor, [flush]),
            {error, invalid_artifact_reconcile_reply};
        {'DOWN', Monitor, process, Pid, _} ->
            {error, artifact_reconcile_handler_down}
    after Timeout ->
        exit(Pid, kill),
        receive {'DOWN', Monitor, process, Pid, _} -> ok after 100 ->
            erlang:demonitor(Monitor, [flush])
        end,
        {error, artifact_reconcile_timeout}
    end.

integer_in(Value, Min, Max) ->
    is_integer(Value) andalso Value >= Min andalso Value =< Max.
