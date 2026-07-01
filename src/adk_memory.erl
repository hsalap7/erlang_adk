-module(adk_memory).

-export([new/0, add_message/3, get_history/1]).

%% @doc Initialize empty memory
new() ->
    [].

%% @doc Add a message to memory
%% Role can be user, agent, or system
add_message(Memory, Role, Content) ->
    Message = #{role => Role, content => Content, timestamp => erlang:system_time(millisecond)},
    [Message | Memory].

%% @doc Get chronological history
get_history(Memory) ->
    lists:reverse(Memory).
