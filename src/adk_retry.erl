%% @doc adk_retry - Retry mechanism with exponential backoff.
-module(adk_retry).

-export([execute/2, execute/4]).

-type retry_opts() :: #{
    max_attempts => pos_integer(),
    initial_delay => pos_integer(),
    max_delay => pos_integer(),
    backoff_factor => float()
}.

%% @doc Execute a function with default retry options.
-spec execute(Fun :: fun(() -> {ok, term()} | {error, term()}), retry_opts()) -> {ok, term()} | {error, term()}.
execute(Fun, Opts) ->
    MaxAttempts = maps:get(max_attempts, Opts, 3),
    InitialDelay = maps:get(initial_delay, Opts, 1000),
    execute(Fun, MaxAttempts, InitialDelay, Opts).

execute(Fun, 1, _Delay, _Opts) ->
    %% Last attempt
    Fun();
execute(Fun, AttemptsLeft, Delay, Opts) ->
    case Fun() of
        {ok, Result} -> {ok, Result};
        {error, _Reason} ->
            timer:sleep(Delay),
            NextDelay = erlang:min(
                maps:get(max_delay, Opts, 10000), 
                erlang:round(Delay * maps:get(backoff_factor, Opts, 2.0))
            ),
            execute(Fun, AttemptsLeft - 1, NextDelay, Opts)
    end.
