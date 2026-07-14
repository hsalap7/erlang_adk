%% Deterministic authentication provider used by token-manager tests.
-module(adk_auth_fake_provider).

-behaviour(adk_auth_provider).

-export([refresh/2]).

refresh(Credential, Context) ->
    Counter = maps:get(counter, Context),
    Count = ets:update_counter(Counter, refreshes, 1, {refreshes, 0}),
    maybe_notify(Context, Count),
    maybe_delay(maps:get(delay_ms, Context, 0)),
    case maps:get(mode, Context, success) of
        success ->
            Prefix = maps:get(token_prefix, Credential, <<"token">>),
            Token = <<Prefix/binary, "-", (integer_to_binary(Count))/binary>>,
            {ok, #{access_token => Token,
                   token_type => <<"Bearer">>,
                   expires_in_ms => maps:get(ttl_ms, Context, 1000)}};
        failure ->
            Secret = maps:get(client_secret, Credential),
            {error,
             #{message => <<"provider rejected ", Secret/binary>>,
               headers => [{<<"Authorization">>,
                            <<"Bearer ", Secret/binary>>}],
               url => <<"https://user:", Secret/binary,
                        "@auth.invalid/token?client_secret=", Secret/binary>>}};
        exception ->
            erlang:error({provider_crash,
                          maps:get(client_secret, Credential)});
        invalid ->
            {ok, #{access_token => maps:get(client_secret, Credential),
                   expires_in_ms => 0}}
    end.

maybe_delay(0) -> ok;
maybe_delay(Milliseconds) when is_integer(Milliseconds), Milliseconds > 0 ->
    timer:sleep(Milliseconds).

maybe_notify(Context, Count) ->
    case maps:get(notify, Context, undefined) of
        Pid when is_pid(Pid) -> Pid ! {fake_provider_started, self(), Count};
        undefined -> ok
    end.
