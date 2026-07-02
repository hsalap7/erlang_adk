%% @doc adk_memory_ets - ETS-backed implementation of adk_memory_service.
%%
%% Simulates a semantic memory service using simple text matching.
-module(adk_memory_ets).
-behaviour(adk_memory_service).

-export([init/1, add/3, search/4, delete/2, add_session_to_memory/3]).

-record(state, {table}).

init(_Config) ->
    %% We spawn a gen_server or just use a named public ETS table for simplicity
    Table = ets:new(adk_memory_ets, [set, public, {read_concurrency, true}, {write_concurrency, true}]),
    {ok, spawn(fun() -> loop(#state{table = Table}) end)}.

loop(State) ->
    receive
        {add, From, Content, Metadata} ->
            Id = generate_id(),
            ets:insert(State#state.table, {Id, Content, Metadata}),
            From ! {memory_reply, {ok, Id}},
            loop(State);
        {search, From, Query, _Filter, Limit} ->
            %% Naive substring search instead of vector similarity
            MatchSpec = [{'$1', [], ['$1']}],
            All = ets:select(State#state.table, MatchSpec),
            QStr = string:to_lower(binary_to_list(Query)),
            Results = lists:foldl(fun({Id, Content, Metadata}, Acc) ->
                CStr = string:to_lower(binary_to_list(Content)),
                case string:find(CStr, QStr) of
                    nomatch -> Acc;
                    _ -> [#{id => Id, content => Content, metadata => Metadata, score => 1.0} | Acc]
                end
            end, [], All),
            Sorted = lists:sublist(Results, Limit),
            From ! {memory_reply, {ok, Sorted}},
            loop(State);
        {delete, From, Id} ->
            ets:delete(State#state.table, Id),
            From ! {memory_reply, ok},
            loop(State);
        {add_session, From, SessionId, Events} ->
            %% Combine all event texts into one document
            Content = lists:foldl(fun(E, Acc) ->
                case adk_event:to_map(E) of
                    #{<<"content">> := #{<<"type">> := <<"text">>, <<"text">> := Text}} ->
                        <<Acc/binary, "\n", Text/binary>>;
                    _ -> Acc
                end
            end, <<>>, Events),
            
            if size(Content) > 0 ->
                Id = generate_id(),
                ets:insert(State#state.table, {Id, Content, #{<<"session_id">> => SessionId}}),
                From ! {memory_reply, ok};
            true ->
                From ! {memory_reply, ok}
            end,
            loop(State)
    end.

%% API Wrappers

add(Pid, Content, Metadata) ->
    Pid ! {add, self(), Content, Metadata},
    receive {memory_reply, Result} -> Result after 5000 -> {error, timeout} end.

search(Pid, Query, Filter, Limit) ->
    Pid ! {search, self(), Query, Filter, Limit},
    receive {memory_reply, Result} -> Result after 5000 -> {error, timeout} end.

delete(Pid, Id) ->
    Pid ! {delete, self(), Id},
    receive {memory_reply, Result} -> Result after 5000 -> {error, timeout} end.

add_session_to_memory(Pid, SessionId, Events) ->
    Pid ! {add_session, self(), SessionId, Events},
    receive {memory_reply, Result} -> Result after 5000 -> {error, timeout} end.

%% Internal Functions

generate_id() ->
    <<A:32, B:16, C:16, D:16, E:48>> = crypto:strong_rand_bytes(16),
    List = io_lib:format("mem-~8.16.0b-~4.16.0b-4~3.16.0b-~4.16.0b-~12.16.0b", 
                         [A, B, C band 16#0fff, D band 16#3fff bor 16#8000, E]),
    list_to_binary(List).
