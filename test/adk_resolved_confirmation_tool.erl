-module(adk_resolved_confirmation_tool).
-behaviour(adk_tool).

-export([schema/0, require_confirmation/2, execute/2,
         set_target/1, clear_target/0]).

-define(TARGET_KEY, {?MODULE, target}).

set_target(TestPid) when is_pid(TestPid) ->
    persistent_term:put(?TARGET_KEY, TestPid),
    ok.

clear_target() ->
    persistent_term:erase(?TARGET_KEY),
    ok.

schema() ->
    #{<<"name">> => <<"dynamic_echo">>,
      <<"description">> => <<"Resolved local confirmation probe">>,
      <<"parameters">> =>
          #{<<"type">> => <<"object">>,
            <<"properties">> =>
                #{<<"text">> => #{<<"type">> => <<"string">>}},
            <<"required">> => [<<"text">>],
            <<"additionalProperties">> => false}}.

require_confirmation(Args, Context) ->
    notify({resolved_module_confirmation_checked, Args, Context}),
    #{required => true,
      hint => <<"Approve the resolved local module">>}.

execute(Args, Context) ->
    notify({resolved_module_executed, Args, Context}),
    {ok, #{<<"echo">> => maps:get(<<"text">>, Args)}}.

notify(Message) ->
    case persistent_term:get(?TARGET_KEY, undefined) of
        TestPid when is_pid(TestPid) -> TestPid ! Message;
        _ -> ok
    end.
