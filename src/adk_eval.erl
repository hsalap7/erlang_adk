%% @doc adk_eval - Lightweight evaluation helpers for Erlang ADK.
%%
%% Allows defining datasets and running them against an agent to calculate metrics.
-module(adk_eval).

-export([run/3, run/4]).

-type dataset() :: [#{input => term(), expected => term(), metadata => map()}].
-type metric_fn() :: fun((Expected :: term(), Actual :: term()) -> float()).

%% @doc Run an evaluation.
-spec run(AgentRef :: term(), Dataset :: dataset(), MetricFn :: metric_fn()) -> {ok, map()} | {error, term()}.
run(AgentRef, Dataset, MetricFn) ->
    run(AgentRef, Dataset, MetricFn, #{}).

%% @doc Run an evaluation with options (e.g. concurrency).
%%
%% `concurrency` controls the number of evaluator worker processes. Calls made
%% to one stateful agent pid are still serialized by that agent's gen_server;
%% use separate agent processes when model calls themselves must overlap.
-spec run(AgentRef :: term(), Dataset :: dataset(), MetricFn :: metric_fn(), Opts :: map()) -> {ok, map()} | {error, term()}.
run(AgentRef, Dataset, MetricFn, Opts)
  when is_list(Dataset), is_function(MetricFn, 2), is_map(Opts) ->
    Concurrency = maps:get(concurrency, Opts, 1),
    Timeout = maps:get(timeout, Opts, 60000),
    case validate_options(Concurrency, Timeout) of
        ok ->
            EvalFun = fun(Row) -> evaluate_row(AgentRef, Row, MetricFn) end,
            %% Use monitored workers even at concurrency=1 so the timeout has
            %% identical meaning in sequential and parallel evaluations.
            Results = map_in_batches(
                        EvalFun, Dataset, Concurrency, Timeout, []),

            TotalScore = lists:sum([maps:get(score, R) || R <- Results]),
            AvgScore = case Results of
                [] -> 0.0;
                _ -> TotalScore / length(Results)
            end,
            TotalDuration = lists:sum(
                              [maps:get(duration, R) || R <- Results]),

            {ok, #{average_score => AvgScore,
                   total_duration_ms => TotalDuration,
                   results => Results}};
        {error, _} = Error ->
            Error
    end;
run(_AgentRef, _Dataset, _MetricFn, _Opts) ->
    {error, invalid_evaluation_arguments}.

evaluate_row(AgentRef, Row, MetricFn) ->
    Input = maps:get(input, Row),
    Expected = maps:get(expected, Row),
    Start = erlang:monotonic_time(millisecond),
    PromptResult = try erlang_adk:prompt(AgentRef, Input) of
        PromptValue -> PromptValue
    catch
        Class:PromptFailure -> {error, {Class, PromptFailure}}
    end,
    Duration = erlang:monotonic_time(millisecond) - Start,
    case PromptResult of
        {ok, Response} ->
            Score = try MetricFn(Expected, Response) of
                MetricValue when is_number(MetricValue) -> MetricValue
            catch
                _:_ -> 0.0
            end,
            #{input => Input, expected => Expected, actual => Response,
              score => Score, duration => Duration,
              metadata => maps:get(metadata, Row, #{})};
        {error, PromptError} ->
            #{input => Input, expected => Expected, actual => undefined,
              score => 0.0, duration => Duration,
              metadata => maps:get(metadata, Row, #{}), error => PromptError}
    end.

map_in_batches(_Fun, [], _Concurrency, _Timeout, Acc) ->
    lists:append(lists:reverse(Acc));
map_in_batches(Fun, Items, Concurrency, Timeout, Acc) ->
    BatchSize = erlang:min(Concurrency, length(Items)),
    {Batch, Rest} = lists:split(BatchSize, Items),
    Results = parallel_batch(Fun, Batch, Timeout),
    map_in_batches(Fun, Rest, Concurrency, Timeout, [Results | Acc]).

parallel_batch(Fun, Items, Timeout) ->
    Parent = self(),
    Jobs = lists:map(fun({Index, Item}) ->
        Ref = make_ref(),
        StartedAt = erlang:monotonic_time(millisecond),
        {Pid, Monitor} = spawn_monitor(fun() ->
            Result = try Fun(Item) of
                Value -> Value
            catch
                Class:Reason ->
                    failed_result(Item, {Class, Reason}, elapsed_ms(StartedAt))
            end,
            Parent ! {Ref, Result}
        end),
        {Index, Item, StartedAt, Ref, Pid, Monitor}
    end, lists:enumerate(Items)),
    Deadline = eval_deadline(Timeout),
    [collect_eval_job(Job, Deadline) || Job <- Jobs].

collect_eval_job({_Index, Item, StartedAt, Ref, Pid, Monitor}, Deadline) ->
    Remaining = eval_remaining(Deadline),
    receive
        {Ref, Result} ->
            erlang:demonitor(Monitor, [flush]),
            Result;
        {'DOWN', Monitor, process, Pid, Reason} ->
            failed_result(Item, {worker_down, Reason}, elapsed_ms(StartedAt))
    after Remaining ->
        exit(Pid, kill),
        erlang:demonitor(Monitor, [flush]),
        failed_result(Item, timeout, elapsed_ms(StartedAt))
    end.

failed_result(Row, Error, Duration) when is_map(Row) ->
    #{input => maps:get(input, Row, undefined),
      expected => maps:get(expected, Row, undefined),
      actual => undefined,
      score => 0.0,
      duration => Duration,
      metadata => maps:get(metadata, Row, #{}),
      error => Error};
failed_result(_Row, Error, Duration) ->
    #{input => undefined,
      expected => undefined,
      actual => undefined,
      score => 0.0,
      duration => Duration,
      metadata => #{},
      error => Error}.

elapsed_ms(StartedAt) ->
    erlang:max(0, erlang:monotonic_time(millisecond) - StartedAt).

validate_options(Concurrency, Timeout)
  when is_integer(Concurrency), Concurrency > 0,
       (Timeout =:= infinity orelse
        (is_integer(Timeout) andalso Timeout >= 0)) ->
    ok;
validate_options(Concurrency, _Timeout)
  when not is_integer(Concurrency); Concurrency =< 0 ->
    {error, {invalid_concurrency, Concurrency}};
validate_options(_Concurrency, Timeout) ->
    {error, {invalid_timeout, Timeout}}.

eval_deadline(infinity) -> infinity;
eval_deadline(Timeout) -> erlang:monotonic_time(millisecond) + Timeout.

eval_remaining(infinity) -> infinity;
eval_remaining(Deadline) ->
    erlang:max(0, Deadline - erlang:monotonic_time(millisecond)).
