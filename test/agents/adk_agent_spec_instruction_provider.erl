-module(adk_agent_spec_instruction_provider).

-export([scoped/1, global_scoped/1, crashes/1, times_out/1, returns_error/1,
         invalid_result/1]).

scoped(Context) ->
    State = maps:get(state, Context),
    SecretPresent = maps:is_key(<<"api_key">>, State) orelse
                    maps:is_key(<<"client_secret">>, State) orelse
                    maps:is_key(credential_ref, Context),
    case SecretPresent of
        true -> <<"UNSAFE">>;
        false -> <<"Dynamic hello {user:name}; {artifact.guide.txt}">>
    end.

global_scoped(_Context) ->
    <<"Global {user:name}.">>.

crashes(_Context) ->
    erlang:error({callback_secret, <<"must-never-escape">>}).

times_out(_Context) ->
    maybe_probe({started, self()}),
    timer:sleep(250),
    maybe_probe({finished, self()}),
    <<"too late">>.

returns_error(_Context) ->
    {error, {private_failure, <<"must-never-escape">>}}.

invalid_result(_Context) ->
    #{value => instruction_text}.

maybe_probe(Value) ->
    case ets:whereis(adk_agent_spec_callback_probe) of
        undefined -> ok;
        Table -> true = ets:insert(Table, Value)
    end.
