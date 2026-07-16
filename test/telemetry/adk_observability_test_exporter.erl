-module(adk_observability_test_exporter).
-behaviour(adk_observability_exporter).

-export([export/2]).

export(Envelope, Config) ->
    case maps:get(test_pid, Config, undefined) of
        Pid when is_pid(Pid) ->
            Pid ! {exported, maps:get(label, Config, undefined), Envelope};
        _ -> ok
    end,
    case maps:get(action, Config, ok) of
        ok -> ok;
        error -> {error, deliberately_failed};
        fail_end ->
            case maps:get(<<"phase">>, Envelope, undefined) of
                <<"end">> -> {error, deliberately_failed_end};
                _ -> ok
            end;
        crash -> erlang:error(deliberately_crashed);
        owner_fence ->
            %% A linked guard exit with reason `killed` is trappable. Tests use
            %% this callback to prove the framework sends a direct `kill`.
            process_flag(trap_exit, true),
            case maps:get(test_pid, Config, undefined) of
                Owner when is_pid(Owner) ->
                    Owner ! {exporter_callback_started, self()};
                _ -> ok
            end,
            receive release_exporter -> ok end;
        timeout ->
            timer:sleep(maps:get(delay_ms, Config, 1000)),
            ok
    end.
