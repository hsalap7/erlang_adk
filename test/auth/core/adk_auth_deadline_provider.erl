%% Deterministic fixture for refresh-worker lifecycle and deadline tests.
-module(adk_auth_deadline_provider).

-behaviour(adk_auth_provider).

-export([refresh/2]).

refresh(_Credential, #{test_pid := TestPid,
                       credential_rotator := Rotator})
  when is_pid(TestPid), is_function(Rotator, 2) ->
    TestPid ! {deadline_provider_started, self(), Rotator},
    receive
        release ->
            {ok, #{access_token => <<"released">>,
                   token_type => <<"Bearer">>, expires_in_ms => 1000}}
    end.
