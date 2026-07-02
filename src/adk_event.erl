%% @doc adk_event - Immutable event records for the ADK event system.
%%
%% Events are the fundamental unit of communication in the ADK 2.0 architecture.
%% Every agent action, tool call, and state change is recorded as an event.
-module(adk_event).

-export([new/2, new/3, with_state_delta/2, is_final_response/1, to_map/1, from_map/1]).

-include("../include/adk_event.hrl").

-type event() :: #adk_event{}.
-export_type([event/0]).

%% @doc Create a new immutable event record with auto-generated ID and timestamp.
%% Author is the name of the agent or <<"user">>.
%% Content can be text (binary), {tool_calls, List}, or {tool_response, ...}.
-spec new(Author :: binary(), Content :: term()) -> event().
new(Author, Content) ->
    new(Author, Content, #{}).

%% @doc Create a new immutable event record with options.
%% Opts can include: partial (boolean), is_final (boolean), actions (map), invocation_id (binary).
-spec new(Author :: binary(), Content :: term(), Opts :: map()) -> event().
new(Author, Content, Opts) ->
    #adk_event{
        id = generate_id(),
        invocation_id = maps:get(invocation_id, Opts, generate_id()),
        author = Author,
        content = Content,
        actions = maps:get(actions, Opts, #{}),
        timestamp = erlang:system_time(millisecond),
        partial = maps:get(partial, Opts, false),
        is_final = maps:get(is_final, Opts, false)
    }.

%% @doc Attach a state delta map to an existing event.
-spec with_state_delta(Event :: event(), Delta :: map()) -> event().
with_state_delta(Event, Delta) ->
    Actions = Event#adk_event.actions,
    NewActions = Actions#{<<"state_delta">> => Delta},
    Event#adk_event{actions = NewActions}.

%% @doc Check if this is the terminal event in an invocation.
-spec is_final_response(Event :: event()) -> boolean().
is_final_response(#adk_event{is_final = true}) -> true;
is_final_response(_) -> false.

%% @doc Serialize an event to a map for JSON encoding or persistence.
-spec to_map(Event :: event()) -> map().
to_map(#adk_event{id = Id, invocation_id = InvId, author = Author, content = Content, 
                  actions = Actions, timestamp = Ts, partial = Partial, is_final = IsFinal}) ->
    #{
        <<"id">> => Id,
        <<"invocation_id">> => InvId,
        <<"author">> => Author,
        <<"content">> => format_content(Content),
        <<"actions">> => Actions,
        <<"timestamp">> => Ts,
        <<"partial">> => Partial,
        <<"is_final">> => IsFinal
    }.

%% @doc Deserialize an event from a map.
-spec from_map(Map :: map()) -> event().
from_map(Map) ->
    #adk_event{
        id = maps:get(<<"id">>, Map),
        invocation_id = maps:get(<<"invocation_id">>, Map),
        author = maps:get(<<"author">>, Map),
        content = parse_content(maps:get(<<"content">>, Map)),
        actions = maps:get(<<"actions">>, Map, #{}),
        timestamp = maps:get(<<"timestamp">>, Map),
        partial = maps:get(<<"partial">>, Map, false),
        is_final = maps:get(<<"is_final">>, Map, false)
    }.

%% Internal Functions

%% @private Generate a simple pseudo-random UUID-like string.
generate_id() ->
    <<A:32, B:16, C:16, D:16, E:48>> = crypto:strong_rand_bytes(16),
    List = io_lib:format("~8.16.0b-~4.16.0b-4~3.16.0b-~4.16.0b-~12.16.0b", 
                         [A, B, C band 16#0fff, D band 16#3fff bor 16#8000, E]),
    list_to_binary(List).

%% @private Format content for map serialization.
format_content({tool_calls, Calls}) ->
    #{<<"type">> => <<"tool_calls">>, <<"calls">> => Calls};
format_content({tool_response, NameBin, Result, Sig}) ->
    #{<<"type">> => <<"tool_response">>, <<"name">> => NameBin, <<"result">> => Result, <<"signature">> => Sig};
format_content(Text) when is_binary(Text) ->
    #{<<"type">> => <<"text">>, <<"text">> => Text};
format_content(Text) when is_list(Text) ->
    #{<<"type">> => <<"text">>, <<"text">> => list_to_binary(Text)};
format_content(Other) ->
    #{<<"type">> => <<"unknown">>, <<"data">> => list_to_binary(io_lib:format("~p", [Other]))}.

%% @private Parse content from map serialization.
parse_content(#{<<"type">> := <<"tool_calls">>, <<"calls">> := Calls}) ->
    {tool_calls, Calls};
parse_content(#{<<"type">> := <<"tool_response">>, <<"name">> := NameBin, <<"result">> := Result, <<"signature">> := Sig}) ->
    {tool_response, NameBin, Result, Sig};
parse_content(#{<<"type">> := <<"text">>, <<"text">> := Text}) ->
    Text;
parse_content(#{<<"type">> := <<"unknown">>, <<"data">> := Data}) ->
    Data;
parse_content(Other) ->
    Other.
