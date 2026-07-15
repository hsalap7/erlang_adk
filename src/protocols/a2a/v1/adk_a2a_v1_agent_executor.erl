%% @doc Default bridge from an A2A 1.0 server to a registered Erlang ADK agent.
-module(adk_a2a_v1_agent_executor).

-export([execute/2]).

execute(#{message := Message}, _Emit) ->
    case application:get_env(erlang_adk, a2a_v1_agent_name) of
        {ok, AgentName} when is_binary(AgentName) ->
            case adk_agent_registry:lookup(AgentName) of
                {ok, Agent} ->
                    case message_text(Message) of
                        {ok, Prompt} -> erlang_adk:prompt(Agent, Prompt);
                        {error, _} = Error -> Error
                    end;
                {error, not_found} -> {failed, agent_not_found}
            end;
        _ -> {failed, agent_not_configured}
    end.

message_text(#{<<"parts">> := Parts}) ->
    Text = [Value || #{<<"text">> := Value} <- Parts],
    case Text of
        [] -> {error, text_input_required};
        _ -> {ok, iolist_to_binary(lists:join(<<"\n">>, Text))}
    end.
