-module(adk_test_toolset).

-export([schemas/1, resolved_call/4]).

schemas(_Handle) ->
    [#{<<"name">> => <<"dynamic_echo">>,
       <<"description">> => <<"Echo through a resolved toolset call">>,
       <<"parameters">> =>
           #{<<"type">> => <<"object">>,
             <<"properties">> =>
                 #{<<"text">> => #{<<"type">> => <<"string">>}},
             <<"required">> => [<<"text">>]}}].

resolved_call(Handle, <<"dynamic_echo">>, Args, Context)
  when is_pid(Handle) ->
    Execute = fun() ->
        Handle ! {dynamic_tool_executed, self(), Args, Context},
        {ok, #{<<"echo">> => maps:get(<<"text">>, Args)}}
    end,
    {ok, #{name => <<"dynamic_echo">>,
           args => Args,
           execute => Execute,
           parallel_safe => true,
           pause_capable => false,
           timeout => 1000}};
resolved_call(_Handle, _Name, _Args, _Context) ->
    {error, unknown_tool}.
