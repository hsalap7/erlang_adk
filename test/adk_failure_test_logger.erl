-module(adk_failure_test_logger).

-export([adding_handler/1, changing_config/3,
         removing_handler/1, log/2]).

adding_handler(Config) -> {ok, Config}.

changing_config(_SetOrUpdate, OldConfig, NewConfig) ->
    {ok, maps:merge(OldConfig, NewConfig)}.

removing_handler(_Config) -> ok.

log(LogEvent, HandlerConfig) ->
    Config = maps:get(config, HandlerConfig, #{}),
    case maps:get(observer, Config, undefined) of
        Pid when is_pid(Pid) -> Pid ! {captured_log, LogEvent};
        _ -> ok
    end,
    ok.
