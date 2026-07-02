%% @doc adk_eval - Evaluation framework for ADK 2.0.
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
-spec run(AgentRef :: term(), Dataset :: dataset(), MetricFn :: metric_fn(), Opts :: map()) -> {ok, map()} | {error, term()}.
run(AgentRef, Dataset, MetricFn, _Opts) ->
    %% Simplified synchronous evaluation for now
    Results = lists:map(fun(Row) ->
        Input = maps:get(input, Row),
        Expected = maps:get(expected, Row),
        
        %% Execute Agent
        Start = erlang:monotonic_time(millisecond),
        {ok, Response} = erlang_adk:prompt(AgentRef, Input),
        Duration = erlang:monotonic_time(millisecond) - Start,
        
        %% Calculate score
        Score = MetricFn(Expected, Response),
        
        #{
            input => Input,
            expected => Expected,
            actual => Response,
            score => Score,
            duration => Duration
        }
    end, Dataset),
    
    %% Aggregate metrics
    TotalScore = lists:sum([maps:get(score, R) || R <- Results]),
    AvgScore = if length(Results) > 0 -> TotalScore / length(Results); true -> 0.0 end,
    
    TotalDuration = lists:sum([maps:get(duration, R) || R <- Results]),
    
    {ok, #{
        average_score => AvgScore,
        total_duration_ms => TotalDuration,
        results => Results
    }}.
