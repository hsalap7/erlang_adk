-module(adk_eval_set_test_adapter).
-behaviour(adk_eval_adapter).

-export([run_turn/5]).

run_turn(Target, Turn, State, Context, Config) ->
    tracker_enter(Target),
    try
        maybe_delay(Config),
        case maps:get(mode, Config, stateful) of
            stateful -> stateful_turn(Turn, State, Context);
            echo_expected ->
                output_result(maps:get(<<"expected">>, Turn), State,
                              Turn, Context);
            fail -> {error, deliberately_failed};
            crash -> erlang:error(deliberately_crashed)
        end
    after
        tracker_leave(Target)
    end.

stateful_turn(Turn, State, Context) ->
    Input = maps:get(<<"input">>, Turn),
    case Input of
        <<"store:", Value/binary>> ->
            output_result(<<"stored">>, Value, Turn, Context);
        <<"recall">> when is_binary(State) ->
            output_result(State, State, Turn, Context);
        _ -> output_result(Input, State, Turn, Context)
    end.

output_result(Output, State, Turn, Context) ->
    TurnId = maps:get(<<"turn_id">>, Context),
    CallId = <<"call-", TurnId/binary>>,
    InvocationId = <<"eval-", TurnId/binary>>,
    Input = maps:get(<<"input">>, Turn),
    ToolCall = adk_event:new(
                 <<"eval-agent">>,
                 {tool_calls,
                  [{<<"memory">>, #{<<"value">> => Input},
                    undefined, CallId}]},
                 #{invocation_id => InvocationId}),
    ToolResponse = adk_event:new(
                     <<"tool">>,
                     {tool_response, <<"memory">>,
                      #{<<"output">> => Output}, undefined, CallId},
                     #{invocation_id => InvocationId}),
    {ok, #{output => Output, state => State,
           events => [ToolCall, ToolResponse],
           metadata => #{turn_seen => TurnId,
                         api_key => <<"adapter-secret">>}}}.

maybe_delay(Config) ->
    case maps:get(delay_ms, Config, 0) of
        Delay when is_integer(Delay), Delay > 0 -> timer:sleep(Delay);
        _ -> ok
    end.

tracker_enter(Pid) when is_pid(Pid) ->
    Ref = make_ref(),
    Pid ! {tracker_enter, self(), Ref},
    receive {tracker_ack, Ref} -> ok after 1000 -> exit(tracker_timeout) end;
tracker_enter(_) -> ok.

tracker_leave(Pid) when is_pid(Pid) ->
    Ref = make_ref(),
    Pid ! {tracker_leave, self(), Ref},
    receive {tracker_ack, Ref} -> ok after 1000 -> exit(tracker_timeout) end;
tracker_leave(_) -> ok.
