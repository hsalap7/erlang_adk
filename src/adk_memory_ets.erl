%% @doc adk_memory_ets - ETS-backed implementation of adk_memory_service.
%%
%% Simulates a semantic memory service using simple text matching.
-module(adk_memory_ets).
-behaviour(adk_memory_service).

-export([init/1, add/3, search/4, delete/2, add_session_to_memory/3, stop/1]).

-record(state, {table}).

init(_Config) ->
    Parent = self(),
    Pid = proc_lib:spawn_link(fun() ->
        Table = ets:new(adk_memory_ets, [set, public,
                                        {read_concurrency, true},
                                        {write_concurrency, true}]),
        Parent ! {memory_ready, self()},
        loop(#state{table = Table})
    end),
    receive
        {memory_ready, Pid} -> {ok, Pid}
    after 5000 ->
        exit(Pid, kill),
        {error, init_timeout}
    end.

loop(State) ->
    receive
        {add, From, Ref, Content, Metadata} ->
            Id = generate_id(),
            ets:insert(State#state.table, {Id, Content, Metadata}),
            From ! {memory_reply, Ref, {ok, Id}},
            loop(State);
        {search, From, Ref, Query, Filter, Limit} ->
            %% Deterministic lexical search instead of vector similarity.
            %% Token overlap is more useful than requiring the complete user
            %% prompt to be a literal substring of a stored memory.
            MatchSpec = [{'$1', [], ['$1']}],
            All = ets:select(State#state.table, MatchSpec),
            QueryTokens = search_tokens(Query),
            Results = lists:foldl(fun({Id, Content, Metadata}, Acc) ->
                Score = lexical_score(QueryTokens, search_tokens(Content)),
                case Score > 0.0 andalso metadata_matches(Metadata, Filter) of
                    false -> Acc;
                    true -> [#{id => Id, content => Content,
                               metadata => Metadata, score => Score} | Acc]
                end
            end, [], All),
            Sorted0 = lists:sort(
                        fun(Left, Right) ->
                            {-maps:get(score, Left), maps:get(id, Left)} =<
                            {-maps:get(score, Right), maps:get(id, Right)}
                        end, Results),
            Sorted = lists:sublist(Sorted0, Limit),
            From ! {memory_reply, Ref, {ok, Sorted}},
            loop(State);
        {delete, From, Ref, Id} ->
            ets:delete(State#state.table, Id),
            From ! {memory_reply, Ref, ok},
            loop(State);
        {add_session, From, Ref, SessionId, Events} ->
            %% Combine all event texts into one document
            Content = lists:foldl(fun(E, Acc) ->
                %% Encoding is checked because session history can contain
                %% internal-only action state (for example a continuation).
                %% Such events are not searchable text and must not terminate
                %% the memory service through the strict to_map/1 wrapper.
                case adk_event:encode(E) of
                    {ok, #{<<"content">> := #{<<"type">> := <<"text">>,
                                                  <<"text">> := Text}}} ->
                        <<Acc/binary, "\n", Text/binary>>;
                    _ -> Acc
                end
            end, <<>>, Events),
            
            if size(Content) > 0 ->
                Id = generate_id(),
                ets:insert(State#state.table, {Id, Content, #{<<"session_id">> => SessionId}}),
                From ! {memory_reply, Ref, ok};
            true ->
                From ! {memory_reply, Ref, ok}
            end,
            loop(State);
        stop ->
            ok
    end.

%% API Wrappers

add(Pid, Content, Metadata) ->
    Ref = make_ref(),
    Pid ! {add, self(), Ref, Content, Metadata},
    receive {memory_reply, Ref, Result} -> Result after 5000 -> {error, timeout} end.

search(Pid, Query, Filter, Limit) ->
    Ref = make_ref(),
    Pid ! {search, self(), Ref, Query, Filter, Limit},
    receive {memory_reply, Ref, Result} -> Result after 5000 -> {error, timeout} end.

delete(Pid, Id) ->
    Ref = make_ref(),
    Pid ! {delete, self(), Ref, Id},
    receive {memory_reply, Ref, Result} -> Result after 5000 -> {error, timeout} end.

add_session_to_memory(Pid, SessionId, Events) ->
    Ref = make_ref(),
    Pid ! {add_session, self(), Ref, SessionId, Events},
    receive {memory_reply, Ref, Result} -> Result after 5000 -> {error, timeout} end.

stop(Pid) ->
    Pid ! stop,
    ok.

%% Internal Functions

generate_id() ->
    <<A:32, B:16, C:16, D:16, E:48>> = crypto:strong_rand_bytes(16),
    List = io_lib:format("mem-~8.16.0b-~4.16.0b-4~3.16.0b-~4.16.0b-~12.16.0b", 
                         [A, B, C band 16#0fff, D band 16#3fff bor 16#8000, E]),
    list_to_binary(List).

metadata_matches(_Metadata, Filter) when map_size(Filter) =:= 0 -> true;
metadata_matches(Metadata, Filter) ->
    maps:fold(fun(Key, Value, Matches) ->
        Matches andalso maps:get(Key, Metadata, '$missing') =:= Value
    end, true, Filter).

search_tokens(Text) when is_binary(Text) ->
    Lower = string:lowercase(Text),
    Parts = re:split(Lower, <<"[^\\p{L}\\p{N}_]+">>,
                     [unicode, {return, binary}, trim]),
    lists:usort([Token || Token <- Parts, byte_size(Token) > 0]).

lexical_score([], _ContentTokens) -> 0.0;
lexical_score(QueryTokens, ContentTokens) ->
    Matches = length([Token || Token <- QueryTokens,
                               lists:member(Token, ContentTokens)]),
    Matches / length(QueryTokens).
