-module(adk_phase3_test).
-include_lib("eunit/include/eunit.hrl").
-export([on_tool_start/2]).

agent_tool_test() ->
    Config = #{name => <<"TestAgent">>, description => <<"Does a test">>},
    Schema = adk_agent_tool:schema(Config),
    ?assertEqual(<<"TestAgent">>, maps:get(<<"name">>, Schema)),
    
    %% We expect failure if prompt is missing
    ?assertEqual({error, <<"Missing required parameter 'prompt'">>}, 
                 adk_agent_tool:execute(self(), #{}, #{})).

long_running_tool_test() ->
    Schema = adk_long_running_tool:schema(),
    ?assertEqual(<<"request_human_approval">>, maps:get(<<"name">>, Schema)),
    
    %% Expect a throw of {adk_pause, ...}
    ?assertThrow({adk_pause, human_in_the_loop, <<"Test">>}, 
                 adk_long_running_tool:execute(#{<<"action_summary">> => <<"Test">>})).


on_tool_start(Name, _Args) ->
    put(last_hook, Name),
    ok.

callbacks_test() ->
    put(last_hook, undefined),
    adk_callbacks:execute([?MODULE], on_tool_start, [<<"my_tool">>, #{}]),
    ?assertEqual(<<"my_tool">>, get(last_hook)).
