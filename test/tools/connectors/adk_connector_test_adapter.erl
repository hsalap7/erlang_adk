-module(adk_connector_test_adapter).

-export([schemas/1, resolved_call/4]).

schemas(#{names := Names}) ->
    [#{<<"name">> => Name,
       <<"description">> => <<"Connector test tool">>,
       <<"parameters">> =>
           #{<<"type">> => <<"object">>,
             <<"properties">> => #{},
             <<"additionalProperties">> => false}}
     || Name <- Names].

resolved_call(#{target := Target, decisions := Decisions}, Name, Args, Context) ->
    Target ! {connector_resolved, Name, Args, Context},
    Base = #{name => Name,
             args => Args,
             execute => fun() -> {ok, Name} end,
             pause_capable => false},
    case maps:find(Name, Decisions) of
        {ok, Decision} -> {ok, Base#{confirmation => Decision}};
        error -> {ok, Base}
    end.
