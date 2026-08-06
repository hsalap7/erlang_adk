-module(adk_cli_graph_fixture).

-export([graph/0, not_graph/0, crash/0, execute/2]).

graph() ->
    #{version => 1,
      id => <<"cli-graph-fixture">>,
      kind => graph,
      definition_revision => <<"cli-fixture-v1">>,
      entry => <<"start">>,
      nodes => [#{id => <<"start">>, type => action,
                  run => {?MODULE, execute, []}}],
      edges => #{<<"start">> => end_node},
      max_steps => 2}.

not_graph() ->
    #{version => 1,
      id => <<"cli-not-graph">>,
      kind => sequential,
      steps => [#{id => <<"step">>, run => {?MODULE, execute, []}}]}.

crash() -> erlang:error(factory_crashed).

execute(_State, _Context) -> {ok, #{}}.
