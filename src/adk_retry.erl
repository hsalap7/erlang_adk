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
execute(Fun, Opts) when is_function(Fun, 0), is_map(Opts) ->
    MaxAttempts = maps:get(max_attempts, Opts, 3),
    InitialDelay = maps:get(initial_delay, Opts, 1000),
    MaxDelay = maps:get(max_delay, Opts, 10000),
    Backoff = maps:get(backoff_factor, Opts, 2.0),
    case is_integer(MaxAttempts) andalso MaxAttempts > 0
         andalso is_integer(InitialDelay) andalso InitialDelay >= 0
         andalso is_integer(MaxDelay) andalso MaxDelay >= 0
         andalso is_number(Backoff) andalso Backoff >= 0 of
        true -> execute(Fun, MaxAttempts, InitialDelay, Opts);
        false -> {error, invalid_retry_options}
    end;
execute(_Fun, _Opts) ->
    {error, invalid_retry_options}.

execute(Fun, 1, _Delay, _Opts) ->
    %% Last attempt
    normalize_result(Fun());
execute(Fun, AttemptsLeft, Delay, Opts) ->
    case Fun() of
        {ok, Result} -> {ok, Result};
        {error, _Reason} ->
            timer:sleep(Delay),
            NextDelay = erlang:min(
                maps:get(max_delay, Opts, 10000), 
                erlang:round(Delay * maps:get(backoff_factor, Opts, 2.0))
            ),
            execute(Fun, AttemptsLeft - 1, NextDelay, Opts);
        Other ->
            {error, {invalid_retry_result, Other}}
    end.

normalize_result({ok, _} = Success) -> Success;
normalize_result({error, _} = Error) -> Error;
normalize_result(Other) -> {error, {invalid_retry_result, Other}}.
