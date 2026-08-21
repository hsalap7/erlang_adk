%% @doc Bounded provider contract for memory embeddings.
-module(adk_memory_embedding_provider).

-export([embed/5, default_limits/0, validate_request/4,
         validate_result/3]).
-export_type([service_ref/0, vector/0, result/0]).

-type service_ref() :: {module(), term()}.
-type vector() :: [float()].
-type result() :: #{model := binary(), dimensions := pos_integer(),
                    vectors := [vector()], usage => map()}.

-callback capabilities(Handle :: term()) -> map() | {ok, map()}.
-callback embed(Handle :: term(), Model :: binary(), Inputs :: [binary()],
                Options :: map()) -> {ok, result()} | {error, term()}.

default_limits() ->
    #{timeout_ms => 5000,
      max_inputs => 128,
      max_input_bytes => 65536,
      max_total_input_bytes => 1048576,
      max_dimensions => 8192,
      max_result_bytes => 16777216}.

%% @doc Invoke an embedding provider in a killable bounded worker.
embed({Module, Handle}, Model, Inputs, Options, CallOptions)
  when is_atom(Module), is_map(Options), is_map(CallOptions) ->
    case compile_limits(CallOptions) of
        {ok, Limits} ->
            case validate_request(Model, Inputs, Options, Limits) of
                {ok, Count} ->
                    invoke(Module, Handle, Model, Inputs, Options,
                           Count, Limits);
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end;
embed(_, _, _, _, _) -> {error, invalid_embedding_provider_request}.

validate_request(Model, Inputs, Options, Limits)
  when is_map(Options), is_map(Limits) ->
    UnknownOptions = lists:sort(maps:keys(
                                  maps:without([purpose], Options))),
    case {bounded_binary(Model, 256),
          bounded_inputs(Inputs, Limits), UnknownOptions,
          valid_purpose(maps:get(purpose, Options, document))} of
        {ok, {ok, Count}, [], true} -> {ok, Count};
        {{error, Reason}, _, _, _} ->
            {error, {invalid_embedding_model, Reason}};
        {_, {error, _} = Error, _, _} -> Error;
        {_, _, [_ | _], _} ->
            {error, {invalid_embedding_options,
                     {unknown_keys, UnknownOptions}}};
        {_, _, _, false} -> {error, invalid_embedding_purpose}
    end;
validate_request(_, _, _, _) -> {error, invalid_embedding_provider_request}.

validate_result(Result, Count, Limits)
  when is_map(Result), is_integer(Count), Count >= 0, is_map(Limits) ->
    Unknown = lists:sort(maps:keys(
                           maps:without([model, dimensions, vectors, usage],
                                        Result))),
    Model = maps:get(model, Result, undefined),
    Dimensions = maps:get(dimensions, Result, undefined),
    Vectors = maps:get(vectors, Result, undefined),
    case {Unknown, bounded_binary(Model, 256),
          is_integer(Dimensions) andalso Dimensions > 0 andalso
              Dimensions =< maps:get(max_dimensions, Limits),
          embedding_result_within_limit(Count, Dimensions, Limits),
          bounded_vectors(Vectors, Count, Dimensions),
          valid_usage(maps:get(usage, Result, #{}))} of
        {[], ok, true, true, ok, {ok, SafeUsage}} ->
            {ok, Result#{usage => SafeUsage}};
        {[_ | _], _, _, _, _, _} ->
            {error, {invalid_embedding_result,
                     {unknown_keys, Unknown}}};
        _ -> {error, invalid_embedding_result}
    end;
validate_result(_, _, _) -> {error, invalid_embedding_result}.

compile_limits(Overrides) ->
    Defaults = default_limits(),
    Unknown = lists:sort(maps:keys(maps:without(maps:keys(Defaults),
                                                Overrides))),
    Limits = maps:merge(Defaults, Overrides),
    Checks = [{timeout_ms, 600000}, {max_inputs, 10000},
              {max_input_bytes, 1048576},
              {max_total_input_bytes, 16777216},
              {max_dimensions, 65536},
              {max_result_bytes, 268435456}],
    case {Unknown, lists:all(
                     fun({Key, Max}) ->
                         Value = maps:get(Key, Limits),
                         is_integer(Value) andalso Value > 0 andalso
                             Value =< Max
                     end, Checks)} of
        {[], true} -> {ok, Limits};
        {[_ | _], _} ->
            {error, {invalid_embedding_call_options,
                     {unknown_keys, Unknown}}};
        _ -> {error, invalid_embedding_call_limits}
    end.

invoke(Module, Handle, Model, Inputs, Options, Count, Limits) ->
    case code:ensure_loaded(Module) of
        {module, Module} ->
            case erlang:function_exported(Module, embed, 4) of
                true ->
                    Parent = self(),
                    Ref = make_ref(),
                    Fun = fun() ->
                        Reply = try Module:embed(
                                      Handle, Model, Inputs, Options) of
                            Value -> Value
                        catch Class:Reason ->
                            {error, {provider_exception, Class, Reason}}
                        end,
                        Parent ! {Ref, self(), Reply}
                    end,
                    {Pid, Monitor} = spawn_monitor(Fun),
                    await(Pid, Monitor, Ref, Model, Count, Limits);
                false -> {error, embedding_provider_callback_missing}
            end;
        {error, _} -> {error, embedding_provider_unavailable}
    end.

await(Pid, Monitor, Ref, Model, Count, Limits) ->
    receive
        {Ref, Pid, {ok, Result}} ->
            erlang:demonitor(Monitor, [flush]),
            case validate_result(Result, Count, Limits) of
                {ok, #{model := Model} = Validated} -> {ok, Validated};
                {ok, _OtherModel} -> {error, embedding_model_mismatch};
                {error, _} = Error -> Error
            end;
        {Ref, Pid, {error, Reason}} ->
            erlang:demonitor(Monitor, [flush]),
            {error, {embedding_provider_failure, safe_reason(Reason)}};
        {Ref, Pid, _Other} ->
            erlang:demonitor(Monitor, [flush]),
            {error, invalid_embedding_provider_reply};
        {'DOWN', Monitor, process, Pid, _Reason} ->
            {error, embedding_provider_down}
    after maps:get(timeout_ms, Limits) ->
        exit(Pid, kill),
        receive {'DOWN', Monitor, process, Pid, _} -> ok after 100 ->
            erlang:demonitor(Monitor, [flush])
        end,
        {error, embedding_provider_timeout}
    end.

bounded_inputs(Inputs, Limits) when is_list(Inputs) ->
    MaxCount = maps:get(max_inputs, Limits),
    MaxEach = maps:get(max_input_bytes, Limits),
    MaxTotal = maps:get(max_total_input_bytes, Limits),
    bounded_inputs(Inputs, MaxCount, MaxEach, MaxTotal, 0, 0);
bounded_inputs(_, _) -> {error, invalid_embedding_inputs}.

bounded_inputs([], _MaxCount, _MaxEach, _MaxTotal, 0, _Bytes) ->
    {error, empty_embedding_inputs};
bounded_inputs([], _MaxCount, _MaxEach, _MaxTotal, Count, _Bytes) ->
    {ok, Count};
bounded_inputs([Input | Rest], MaxCount, MaxEach, MaxTotal, Count, Bytes)
  when Count < MaxCount ->
    case bounded_binary(Input, MaxEach) of
        ok when Bytes + byte_size(Input) =< MaxTotal ->
            bounded_inputs(Rest, MaxCount, MaxEach, MaxTotal,
                           Count + 1, Bytes + byte_size(Input));
        ok -> {error, embedding_total_input_limit_exceeded};
        {error, Reason} -> {error, {invalid_embedding_input, Reason}}
    end;
bounded_inputs(_, _, _, _, _, _) ->
    {error, embedding_input_count_limit_exceeded}.

bounded_vectors(Vectors, Count, Dimensions) when is_list(Vectors) ->
    case length(Vectors) =:= Count of
        true -> case lists:all(fun(Vector) ->
                     valid_vector(Vector, Dimensions)
                 end, Vectors) of
            true -> ok;
            false -> error
        end;
        false -> error
    end;
bounded_vectors(_, _, _) -> error.

valid_vector(Vector, Dimensions) when is_list(Vector), is_integer(Dimensions) ->
    length(Vector) =:= Dimensions andalso
        lists:all(fun finite_number/1, Vector);
valid_vector(_, _) -> false.

embedding_result_within_limit(Count, Dimensions, Limits)
  when is_integer(Dimensions), Dimensions > 0 ->
    %% A numeric list cell plus boxed float is conservatively budgeted at 16
    %% bytes. This rejects oversized provider replies without serializing and
    %% duplicating the entire result in the caller process.
    Count * Dimensions * 16 =< maps:get(max_result_bytes, Limits);
embedding_result_within_limit(_, _, _) -> false.

finite_number(Value) when is_integer(Value) -> true;
finite_number(Value) when is_float(Value) ->
    Value =:= Value andalso abs(Value) =< 1.0e308;
finite_number(_) -> false.

valid_usage(Usage) when is_map(Usage) ->
    case adk_json:normalize(adk_secret_redactor:redact(Usage)) of
        {ok, Safe} ->
            case byte_size(jsx:encode(Safe)) =< 16384 of
                true -> {ok, Safe};
                false -> error
            end;
        _ -> error
    end;
valid_usage(_) -> error.

valid_purpose(document) -> true;
valid_purpose(query) -> true;
valid_purpose(_) -> false.

bounded_binary(Value, Max) when is_binary(Value) ->
    Size = byte_size(Value),
    case Size > 0 andalso Size =< Max andalso
         unicode:characters_to_binary(Value, utf8, utf8) =:= Value andalso
         binary:match(Value, <<0>>) =:= nomatch of
        true -> ok;
        false -> {error, invalid_or_out_of_bounds}
    end;
bounded_binary(_, _) -> {error, expected_binary}.

safe_reason(Reason) ->
    adk_memory_outbox_payload:safe_reason(Reason).
