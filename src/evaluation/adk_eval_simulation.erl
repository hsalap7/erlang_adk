%% @doc Heap-, deadline-, and step-bounded simulator runtime for evaluations.
%%
%% Simulator modules are selected by trusted operator code. Scenario,
%% transcript, turn, effect, and result values cross a strict JSON boundary;
%% simulator-private state stays in the calling evaluation worker and is not
%% persisted or exposed in reports.
-module(adk_eval_simulation).

-export([start/4, next_user/3, handle_effect/3, stop/1,
         capabilities/1]).

-define(DEFAULT_TIMEOUT_MS, 1000).
-define(MAX_TIMEOUT_MS, 30000).
-define(DEFAULT_MAX_STEPS, 100).
-define(MAX_STEPS, 1000).
-define(DEFAULT_MAX_VALUE_BYTES, 1048576).
-define(MAX_VALUE_BYTES, 4194304).
-define(DEFAULT_MAX_HEAP_WORDS, 524288).
-define(MAX_HEAP_WORDS, 2097152).

-spec start(map(), undefined | map(), map(), map()) ->
    {ok, map()} | {error, term()}.
start(User0, Environment0, Scenario, Options0)
  when is_map(User0), (Environment0 =:= undefined orelse
                       is_map(Environment0)), is_map(Scenario),
       is_map(Options0) ->
    case {normalize_options(Options0), descriptor(user, User0),
          descriptor(environment, Environment0)} of
        {{ok, Options}, {ok, User}, {ok, Environment}} ->
            case bounded_json(Scenario, Options) of
                false -> {error, invalid_eval_simulation_scenario};
                true -> init_simulators(User, Environment, Scenario, Options)
            end;
        {{error, _} = Error, _, _} -> Error;
        {_, {error, _} = Error, _} -> Error;
        {_, _, {error, _} = Error} -> Error
    end;
start(_User, _Environment, _Scenario, _Options) ->
    {error, invalid_eval_simulation}.

-spec next_user(map(), [map()], map()) ->
    {continue, map(), map()} | {done, map()} | {error, term()}.
next_user(#{user := User, options := Options, steps := Steps} = Simulation,
          Transcript, Context)
  when is_list(Transcript), is_map(Context) ->
    MaxSteps = maps:get(max_steps, Options),
    case Steps < MaxSteps andalso
         bounded_json(Transcript, Options) andalso
         bounded_json(Context, Options) of
        false when Steps >= MaxSteps ->
            {error, eval_simulation_step_limit_exceeded};
        false -> {error, invalid_eval_simulation_input};
        true ->
            Module = maps:get(module, User),
            Args = [Transcript, maps:get(state, User), Context,
                    maps:get(config, User)],
            case isolated_call(Module, next_turn, Args, Options) of
                {ok, {continue, Turn, State}} ->
                    case bounded_json(Turn, Options) of
                        true ->
                            User1 = User#{state => State},
                            {continue, Turn,
                             Simulation#{user => User1, steps => Steps + 1}};
                        false -> {error, invalid_eval_simulator_turn}
                    end;
                {ok, {done, State}} ->
                    {done, Simulation#{user => User#{state => State}}};
                {ok, {error, _Reason}} -> {error, eval_user_simulator_failed};
                {ok, _} -> {error, invalid_eval_user_simulator_reply};
                {error, _} = Error -> Error
            end
    end;
next_user(_Simulation, _Transcript, _Context) ->
    {error, invalid_eval_simulation_input}.

-spec handle_effect(map(), map(), map()) ->
    {ok, term(), map()} | {error, term()}.
handle_effect(#{environment := undefined}, _Effect, _Context) ->
    {error, eval_environment_simulator_not_configured};
handle_effect(#{environment := Environment, options := Options} = Simulation,
              Effect, Context)
  when is_map(Effect), is_map(Context) ->
    case bounded_json(Effect, Options) andalso bounded_json(Context, Options) of
        false -> {error, invalid_eval_simulation_effect};
        true ->
            Module = maps:get(module, Environment),
            Args = [Effect, maps:get(state, Environment), Context,
                    maps:get(config, Environment)],
            case isolated_call(Module, handle_effect, Args, Options) of
                {ok, {ok, Result, State}} ->
                    case bounded_json(Result, Options) of
                        true ->
                            Environment1 = Environment#{state => State},
                            {ok, Result,
                             Simulation#{environment => Environment1}};
                        false -> {error, invalid_eval_environment_result}
                    end;
                {ok, {error, _Reason, _State}} ->
                    {error, eval_environment_simulator_failed};
                {ok, {error, _Reason}} ->
                    {error, eval_environment_simulator_failed};
                {ok, _} -> {error, invalid_eval_environment_simulator_reply};
                {error, _} = Error -> Error
            end
    end;
handle_effect(_Simulation, _Effect, _Context) ->
    {error, invalid_eval_simulation_effect}.

-spec stop(map()) -> ok.
stop(#{user := User, environment := Environment, options := Options}) ->
    _ = terminate_descriptor(User, Options),
    _ = terminate_descriptor(Environment, Options),
    ok;
stop(_) -> ok.

-spec capabilities(map()) -> map().
capabilities(#{options := Options, environment := Environment,
               steps := Steps}) ->
    #{contract_version => 1,
      user_simulator => true,
      environment_simulator => Environment =/= undefined,
      steps => Steps,
      max_steps => maps:get(max_steps, Options),
      callback_timeout_ms => maps:get(callback_timeout_ms, Options),
      max_value_bytes => maps:get(max_value_bytes, Options)};
capabilities(_) -> #{}.

init_simulators(User0, Environment0, Scenario, Options) ->
    Context = maps:get(context, Options),
    case init_descriptor(User0, Scenario, Context, Options) of
        {error, _} = Error -> Error;
        {ok, User} ->
            case init_descriptor(Environment0, Scenario, Context, Options) of
                {ok, Environment} ->
                    {ok, #{user => User, environment => Environment,
                           options => Options, steps => 0}};
                {error, _} = Error ->
                    _ = terminate_descriptor(User, Options),
                    Error
            end
    end.

init_descriptor(undefined, _Scenario, _Context, _Options) -> {ok, undefined};
init_descriptor(Descriptor, Scenario, Context, Options) ->
    Module = maps:get(module, Descriptor),
    Config = maps:get(config, Descriptor),
    case erlang:function_exported(Module, init, 3) of
        false -> {ok, Descriptor#{state => undefined}};
        true ->
            case isolated_call(Module, init, [Scenario, Context, Config],
                               Options) of
                {ok, {ok, State}} -> {ok, Descriptor#{state => State}};
                {ok, {error, _}} -> {error, eval_simulator_init_failed};
                {ok, _} -> {error, invalid_eval_simulator_init_reply};
                {error, _} = Error -> Error
            end
    end.

terminate_descriptor(undefined, _Options) -> ok;
terminate_descriptor(#{module := Module, state := State, config := Config},
                     Options) ->
    case erlang:function_exported(Module, terminate, 2) of
        false -> ok;
        true ->
            _ = isolated_call(Module, terminate, [State, Config], Options),
            ok
    end;
terminate_descriptor(_, _Options) -> ok.

descriptor(environment, undefined) -> {ok, undefined};
descriptor(Kind, #{module := Module} = Value) when is_atom(Module) ->
    Config = maps:get(config, Value, #{}),
    Unknown = maps:keys(maps:without([module, config], Value)),
    Callback = case Kind of user -> {next_turn, 4};
                            environment -> {handle_effect, 4} end,
    case {Unknown, is_map(Config), code:ensure_loaded(Module), Callback} of
        {[], true, {module, Module}, {Function, Arity}} ->
            case erlang:function_exported(Module, Function, Arity) of
                true -> {ok, #{module => Module, config => Config}};
                false -> {error, {eval_simulator_missing_callback, Kind}}
            end;
        {[_ | _], _, _, _} ->
            {error, {unknown_eval_simulator_fields, Kind,
                     lists:sort(Unknown)}};
        _ -> {error, {invalid_eval_simulator, Kind}}
    end;
descriptor(Kind, _Value) -> {error, {invalid_eval_simulator, Kind}}.

normalize_options(Options) ->
    Allowed = [callback_timeout_ms, max_steps, max_value_bytes,
               max_heap_words, context],
    Unknown = maps:keys(maps:without(Allowed, Options)),
    Timeout = maps:get(callback_timeout_ms, Options, ?DEFAULT_TIMEOUT_MS),
    Steps = maps:get(max_steps, Options, ?DEFAULT_MAX_STEPS),
    Bytes = maps:get(max_value_bytes, Options, ?DEFAULT_MAX_VALUE_BYTES),
    Heap = maps:get(max_heap_words, Options, ?DEFAULT_MAX_HEAP_WORDS),
    Context = maps:get(context, Options, #{}),
    case {Unknown, within(Timeout, 1, ?MAX_TIMEOUT_MS),
          within(Steps, 1, ?MAX_STEPS),
          within(Bytes, 1, ?MAX_VALUE_BYTES),
          within(Heap, 1024, ?MAX_HEAP_WORDS), is_map(Context)} of
        {[], true, true, true, true, true} ->
            Safe = #{callback_timeout_ms => Timeout, max_steps => Steps,
                     max_value_bytes => Bytes, max_heap_words => Heap,
                     context => Context},
            case bounded_json(Context, Safe) of
                true -> {ok, Safe};
                false -> {error, invalid_eval_simulation_context}
            end;
        {[_ | _], _, _, _, _, _} ->
            {error, {unknown_eval_simulation_options, lists:sort(Unknown)}};
        _ -> {error, invalid_eval_simulation_options}
    end.

isolated_call(Module, Function, Args, Options) ->
    Owner = self(),
    Ref = make_ref(),
    Worker = fun() -> Owner ! {Ref, self(), apply(Module, Function, Args)} end,
    SpawnOptions = [monitor, {message_queue_data, off_heap},
                    {max_heap_size,
                     #{size => maps:get(max_heap_words, Options),
                       kill => true, error_logger => false,
                       include_shared_binaries => true}}],
    try spawn_opt(Worker, SpawnOptions) of
        {Pid, Monitor} ->
            receive
                {Ref, Pid, Result} ->
                    erlang:demonitor(Monitor, [flush]),
                    {ok, Result};
                {'DOWN', Monitor, process, Pid, _Reason} ->
                    {error, eval_simulator_callback_failed}
            after maps:get(callback_timeout_ms, Options) ->
                exit(Pid, kill),
                erlang:demonitor(Monitor, [flush]),
                {error, eval_simulator_callback_timeout}
            end
    catch
        _:_ -> {error, eval_simulator_callback_unavailable}
    end.

bounded_json(Value, Options) ->
    Maximum = maps:get(max_value_bytes, Options),
    case adk_eval_limits:check(
           Value, #{max_external_bytes => Maximum,
                    max_total_binary_bytes => Maximum,
                    max_binary_bytes => Maximum,
                    max_depth => 64, max_nodes => 50000,
                    max_list_length => 10000, max_map_size => 10000}) of
        ok -> json(Value);
        {error, _} -> false
    end.

json(Value) when is_binary(Value) -> true;
json(Value) when is_integer(Value) -> true;
json(Value) when is_float(Value) -> Value =:= Value;
json(true) -> true;
json(false) -> true;
json(null) -> true;
json(Value) when is_list(Value) -> lists:all(fun json/1, Value);
json(Value) when is_map(Value) ->
    lists:all(fun({Key, Nested}) -> is_binary(Key) andalso json(Nested) end,
              maps:to_list(Value));
json(_) -> false.

within(Value, Minimum, Maximum) ->
    is_integer(Value) andalso Value >= Minimum andalso Value =< Maximum.
