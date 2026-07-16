-module(adk_context_capability_tool).
-behaviour(adk_tool).

-export([schema/0, context_capabilities/0, execute/2]).

schema() ->
    #{<<"name">> => <<"capability_writer">>,
      <<"description">> => <<"Writes one scoped artifact">>,
      <<"parameters">> =>
          #{<<"type">> => <<"object">>,
            <<"properties">> => #{},
            <<"additionalProperties">> => false}}.

context_capabilities() -> [artifact_put].

execute(_Args, Context) ->
    adk_context:save_artifact(
      Context, <<"tool.txt">>, <<"scoped">>,
      #{mime_type => <<"text/plain">>}).
