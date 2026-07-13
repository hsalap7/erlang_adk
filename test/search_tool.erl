-module(search_tool).
-behaviour(adk_tool).
-export([schema/0, execute/2]).

schema() ->
    #{<<"name">> => <<"search">>,
      <<"description">> => <<"Search the web">>,
      <<"parameters">> => #{
          <<"type">> => <<"object">>,
          <<"properties">> => #{
              <<"query">> => #{<<"type">> => <<"string">>}
          },
          <<"required">> => [<<"query">>]
      }}.

execute(#{<<"query">> := Query}, _Context) ->
    {ok, <<"Found results for ", Query/binary>>}.
