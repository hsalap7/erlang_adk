-module(adk_catalog_counting_tool).

-export([schema/0, execute/2, set_target/1, clear_target/0]).

-define(TARGET_KEY, {?MODULE, target}).

set_target(TestPid) when is_pid(TestPid) ->
    persistent_term:put(?TARGET_KEY, TestPid),
    ok.

clear_target() ->
    persistent_term:erase(?TARGET_KEY),
    ok.

schema() ->
    case persistent_term:get(?TARGET_KEY, undefined) of
        TestPid when is_pid(TestPid) -> TestPid ! module_schema_read;
        undefined -> ok
    end,
    #{<<"name">> => <<"catalog_counting_tool">>,
      <<"description">> => <<"Catalog compilation fixture">>,
      <<"parameters">> =>
          #{<<"type">> => <<"object">>,
            <<"properties">> =>
                #{<<"value">> => #{<<"type">> => <<"string">>}},
            <<"required">> => [<<"value">>],
            <<"additionalProperties">> => false}}.

execute(Args, _Context) ->
    {ok, Args}.
