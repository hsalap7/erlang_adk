-module(adk_live_session_sup_test).

-include_lib("eunit/include/eunit.hrl").

-define(PRINCIPAL, <<"live-session-limit-principal">>).

bounded_live_session_admission_test_() ->
    {setup,
     fun setup/0,
     fun cleanup/1,
     fun bounded_live_session_admission_case/0}.

setup() ->
    case whereis(adk_live_session_sup) of
        undefined ->
            {ok, Pid} = adk_live_session_sup:start_link(),
            unlink(Pid),
            {started, Pid};
        Pid -> {existing, Pid}
    end.

cleanup({started, Pid}) ->
    Ref = erlang:monitor(process, Pid),
    exit(Pid, shutdown),
    receive
        {'DOWN', Ref, process, Pid, _} -> ok
    after 1000 ->
        erlang:demonitor(Ref, [flush]),
        ok
    end;
cleanup({existing, _Pid}) -> ok.

bounded_live_session_admission_case() ->
    OldLimit = application:get_env(erlang_adk, live_session_limit),
    {ok, Sentinel} = start_session(<<"sentinel">>),
    Before = proplists:get_value(
               specs, supervisor:count_children(adk_live_session_sup)),
    try
        ok = application:set_env(erlang_adk, live_session_limit, 1),
        Parent = self(),
        [spawn(fun() ->
                   Id = <<"over-limit-", (integer_to_binary(I))/binary>>,
                   Parent ! {limit_result,
                             adk_live_session_sup:start_session(
                               Id, ?PRINCIPAL, config())}
               end) || I <- lists:seq(1, 16)],
        Results = [receive
                       {limit_result, Result} -> Result
                   after 2000 -> timeout
                   end || _ <- lists:seq(1, 16)],
        ?assertEqual(lists:duplicate(16, {error, live_session_limit}),
                     lists:sort(Results)),
        After = proplists:get_value(
              specs, supervisor:count_children(adk_live_session_sup)),
        ?assertEqual(Before, After),
        ok = application:set_env(erlang_adk, live_session_limit, 16385),
        ?assertEqual(
           {error, invalid_live_session_limit},
           adk_live_session_sup:start_session(
             <<"invalid-limit">>, ?PRINCIPAL, config()))
    after
        restore_limit(OldLimit),
        _ = adk_live_session:close(Sentinel, ?PRINCIPAL, done)
    end.

start_session(Suffix) ->
    Id = <<"limit-test-", Suffix/binary, "-",
           (integer_to_binary(erlang:unique_integer([positive])))/binary>>,
    Result = adk_live_session_sup:start_session(Id, ?PRINCIPAL, config()),
    case Result of
        {ok, Session} ->
            Handle = receive
                {adk_live_fake_transport, opened, Opened} -> Opened
            after 1000 -> ?assert(false)
            end,
            receive
                {adk_live_fake_transport, sent, Handle, _SetupFrame} -> ok
            after 1000 -> ?assert(false)
            end,
            {ok, Session};
        Other -> Other
    end.

config() ->
    #{provider => adk_live_gemini,
      provider_config => #{},
      transport => adk_live_fake_transport,
      transport_opts => #{test_pid => self()}}.

restore_limit(undefined) ->
    application:unset_env(erlang_adk, live_session_limit);
restore_limit({ok, Limit}) ->
    application:set_env(erlang_adk, live_session_limit, Limit).
