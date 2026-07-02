-module(adk_memory).
-include("../include/adk_event.hrl").

-export([new/0, add_message/3, get_history/1]).
-export([to_events/1, from_events/1]).

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

%% @doc Convert legacy memory list to events
to_events(Memory) ->
    lists:map(fun(Msg) ->
        Role = case maps:get(role, Msg) of
            user -> <<"user">>;
            agent -> <<"agent">>;
            system -> <<"system">>;
            tool -> <<"tool">>;
            Other -> atom_to_binary(Other, utf8)
        end,
        Content = maps:get(content, Msg),
        adk_event:new(Role, Content)
    end, get_history(Memory)).

%% @doc Convert events to legacy memory list
from_events(Events) ->
    lists:foldl(fun(Event, Acc) ->
        Role = try binary_to_existing_atom(Event#adk_event.author, utf8) catch _:_ -> agent end,
        Content = Event#adk_event.content,
        Msg = #{role => Role, content => Content, timestamp => Event#adk_event.timestamp},
        [Msg | Acc]
    end, [], Events).
