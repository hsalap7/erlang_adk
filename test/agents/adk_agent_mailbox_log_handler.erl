-module(adk_agent_mailbox_log_handler).

-export([adding_handler/1, removing_handler/1, changing_config/3, log/2]).

adding_handler(Config) -> {ok, Config}.
removing_handler(_Config) -> ok.
changing_config(_SetOrUpdate, _OldConfig, NewConfig) -> {ok, NewConfig}.

log(Event, Config) ->
    HandlerConfig = maps:get(config, Config, #{}),
    case maps:get(test_pid, HandlerConfig, undefined) of
        Pid when is_pid(Pid) -> Pid ! {agent_mailbox_log, Event};
        _ -> ok
    end.
