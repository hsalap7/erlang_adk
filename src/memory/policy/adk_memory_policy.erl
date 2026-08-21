%% @doc Fail-closed, bounded policy hook for memory governance.
-module(adk_memory_policy).

-export([check/6]).
-export_type([action/0, obligations/0]).

-type action() :: ingest | search | delete | erase | retain | prune.
-type obligations() :: #{expires_at => non_neg_integer(),
                         retain_until => non_neg_integer(),
                         legal_hold => boolean(),
                         consent_id => binary()}.

-callback evaluate(Handle :: term(), Action :: action(),
                   Scope :: adk_memory_service:scope(),
                   Resource :: map(), Context :: map()) ->
    allow | {allow, obligations()} | {deny, atom() | binary()}.

%% @doc Execute a policy callback outside the caller with a hard deadline.
%% Inputs are redacted and normalized before crossing the hook boundary.
check({Module, Handle}, Action, Scope0, Resource0, Context0, Timeout)
  when is_atom(Module), is_atom(Action), is_map(Resource0), is_map(Context0),
       is_integer(Timeout), Timeout > 0, Timeout =< 60000 ->
    case {valid_action(Action),
          adk_memory_contract:validate_scope(Scope0),
          safe_map(Resource0, 65536), safe_map(Context0, 32768)} of
        {true, {ok, Scope}, {ok, Resource}, {ok, Context}} ->
            invoke(Module, Handle, Action, Scope, Resource, Context, Timeout);
        {false, _, _, _} -> {error, invalid_memory_policy_action};
        {_, {error, _} = Error, _, _} -> Error;
        {_, _, {error, _}, _} -> {error, invalid_memory_policy_resource};
        {_, _, _, {error, _}} -> {error, invalid_memory_policy_context}
    end;
check(_, _, _, _, _, _) -> {error, invalid_memory_policy_request}.

invoke(Module, Handle, Action, Scope, Resource, Context, Timeout) ->
    case code:ensure_loaded(Module) of
        {module, Module} ->
            case erlang:function_exported(Module, evaluate, 5) of
                true ->
                    Parent = self(), Ref = make_ref(),
                    {Pid, Monitor} = spawn_monitor(fun() ->
                        Reply = try Module:evaluate(
                                      Handle, Action, Scope,
                                      Resource, Context) of
                            Value -> Value
                        catch _:_ -> policy_callback_failed
                        end,
                        Parent ! {Ref, self(), Reply}
                    end),
                    await(Pid, Monitor, Ref, Timeout);
                false -> {error, memory_policy_callback_missing}
            end;
        {error, _} -> {error, memory_policy_unavailable}
    end.

await(Pid, Monitor, Ref, Timeout) ->
    receive
        {Ref, Pid, Reply} ->
            erlang:demonitor(Monitor, [flush]),
            normalize_decision(Reply);
        {'DOWN', Monitor, process, Pid, _} ->
            {error, memory_policy_unavailable}
    after Timeout ->
        exit(Pid, kill),
        receive {'DOWN', Monitor, process, Pid, _} -> ok after 100 ->
            erlang:demonitor(Monitor, [flush])
        end,
        {error, memory_policy_timeout}
    end.

normalize_decision(allow) -> {ok, #{}};
normalize_decision({allow, Obligations}) when is_map(Obligations) ->
    validate_obligations(Obligations);
normalize_decision({deny, Code}) ->
    case safe_code(Code) of
        {ok, Safe} -> {error, {memory_policy_denied, Safe}};
        error -> {error, memory_policy_denied}
    end;
normalize_decision(_) -> {error, invalid_memory_policy_decision}.

validate_obligations(Map) ->
    Allowed = [expires_at, retain_until, legal_hold, consent_id],
    Unknown = lists:sort(maps:keys(maps:without(Allowed, Map))),
    TimesValid = lists:all(fun(Key) ->
        case maps:find(Key, Map) of
            error -> true;
            {ok, Value} -> is_integer(Value) andalso Value >= 0
        end
    end, [expires_at, retain_until]),
    HoldValid = case maps:find(legal_hold, Map) of
        error -> true;
        {ok, Value} -> is_boolean(Value)
    end,
    ConsentValid = case maps:find(consent_id, Map) of
        error -> true;
        {ok, Value2} -> bounded_binary(Value2, 256)
    end,
    case {Unknown, TimesValid, HoldValid, ConsentValid} of
        {[], true, true, true} -> {ok, Map};
        _ -> {error, invalid_memory_policy_obligations}
    end.

safe_map(Map, Max) ->
    case adk_json:normalize(adk_secret_redactor:redact(Map)) of
        {ok, Safe} when is_map(Safe) ->
            case byte_size(jsx:encode(Safe)) =< Max of
                true -> {ok, Safe};
                false -> {error, size_limit_exceeded}
            end;
        _ -> {error, invalid_map}
    end.

safe_code(Code) when is_atom(Code) -> {ok, Code};
safe_code(Code) when is_binary(Code) ->
    case bounded_binary(Code, 128) of
        true -> {ok, Code};
        false -> error
    end;
safe_code(_) -> error.

bounded_binary(Value, Max) when is_binary(Value) ->
    Size = byte_size(Value),
    Size > 0 andalso Size =< Max andalso
        unicode:characters_to_binary(Value, utf8, utf8) =:= Value andalso
        binary:match(Value, <<0>>) =:= nomatch;
bounded_binary(_, _) -> false.

valid_action(ingest) -> true;
valid_action(search) -> true;
valid_action(delete) -> true;
valid_action(erase) -> true;
valid_action(retain) -> true;
valid_action(prune) -> true;
valid_action(_) -> false.
