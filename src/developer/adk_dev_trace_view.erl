%% @doc Read-only developer projection over the metadata-only trace store.
%%
%% The authenticated principal is supplied by trusted route configuration,
%% never by query parameters.  This module preserves trace-store replay-gap
%% semantics and derives a visual graph overlay without retaining payloads.
-module(adk_dev_trace_view).

-export([query/5, graph_overlay/6]).

-define(MAX_LIMIT, 1000).
-define(MAX_BYTES, 4194304).
-define(MAX_ID_BYTES, 512).

query(Store, Principal, Selector0, Cursor, Options) ->
    case normalize_query(Selector0, Cursor, Options) of
        {ok, Selector, QueryOptions} ->
            adk_trace_store:query(Store, Principal, Selector, QueryOptions);
        {error, _} = Error -> Error
    end.

graph_overlay(Catalog, Owner, GraphId, Store, Principal, Options) ->
    case adk_dev_graph_catalog:get(Catalog, Owner, GraphId) of
        {ok, Graph} -> overlay_for_graph(Graph, Store, Principal, Options);
        {error, _} = Error -> Error
    end.

overlay_for_graph(Graph, Store, Principal, Options) when is_map(Options) ->
    Descriptor = maps:get(<<"graph">>, Graph),
    WorkflowId = maps:get(workflow_id, Options, maps:get(<<"id">>, Graph)),
    Cursor = maps:get(after_cursor, Options, 0),
    QueryOptions = maps:with([limit, max_bytes], Options),
    case query(Store, Principal, #{workflow_id => WorkflowId},
               Cursor, QueryOptions) of
        {ok, Result} ->
            Events = maps:get(<<"events">>, Result),
            Overlay = derive_overlay(Descriptor, Events),
            {ok, #{<<"schema_version">> => 1,
                   <<"content_captured">> => false,
                   <<"graph">> => Graph,
                   <<"overlay">> => Overlay,
                   <<"trace">> => Result}};
        {error, _} = Error -> Error
    end;
overlay_for_graph(_Graph, _Store, _Principal, _Options) ->
    {error, invalid_trace_query_options}.

normalize_query(Selector0, Cursor, Options) when is_map(Options) ->
    Limit = maps:get(limit, Options, 256),
    MaxBytes = maps:get(max_bytes, Options, 1048576),
    case normalize_selector(Selector0) of
        {ok, Selector} when is_integer(Cursor), Cursor >= 0,
                            is_integer(Limit), Limit > 0, Limit =< ?MAX_LIMIT,
                            is_integer(MaxBytes), MaxBytes > 0,
                            MaxBytes =< ?MAX_BYTES ->
            {ok, Selector, #{after_cursor => Cursor, limit => Limit,
                             max_bytes => MaxBytes}};
        {ok, _} -> {error, invalid_trace_query_options};
        {error, _} = Error -> Error
    end;
normalize_query(_Selector, _Cursor, _Options) ->
    {error, invalid_trace_query_options}.

normalize_selector(all) -> {ok, all};
normalize_selector(Selector) when is_map(Selector), map_size(Selector) > 0,
                                  map_size(Selector) =< 4 ->
    Allowed = [run_id, trace_id, workflow_id, invocation_id],
    case lists:all(fun({Key, Value}) ->
                           lists:member(Key, Allowed) andalso valid_id(Value)
                   end, maps:to_list(Selector)) of
        true -> {ok, Selector};
        false -> {error, invalid_trace_selector}
    end;
normalize_selector(_) -> {error, invalid_trace_selector}.

derive_overlay(Descriptor, Events) ->
    Nodes = [maps:get(<<"id">>, Node) || Node <- maps:get(<<"nodes">>, Descriptor, [])],
    Initial = maps:from_list([{Id, <<"idle">>} || Id <- Nodes]),
    {States, Active, Routes, Retries, Pauses} = lists:foldl(
      fun overlay_event/2, {Initial, null, [], 0, 0}, Events),
    #{<<"node_states">> => States,
      <<"active_node">> => Active,
      <<"routes">> => lists:reverse(Routes),
      <<"retry_count">> => Retries,
      <<"pause_count">> => Pauses}.

overlay_event(Wrapper, Acc) ->
    Event = maps:get(<<"event">>, Wrapper, #{}),
    Type = maps:get(<<"type">>, Event, <<>>),
    Node = maps:get(<<"node_id">>, Event, undefined),
    update_overlay(Type, Node, Event, Acc).

update_overlay(Type, Node, Event, {States0, Active0, Routes0, Retries0, Pauses0}) ->
    State = event_state(Type),
    States = case is_binary(Node) andalso maps:is_key(Node, States0) andalso
                  State =/= undefined of
        true -> States0#{Node => State};
        false -> States0
    end,
    Active = case State of
        <<"running">> when is_binary(Node) -> Node;
        _ -> Active0
    end,
    Routes = case {maps:get(<<"from">>, Event, undefined),
                   maps:get(<<"to">>, Event, undefined)} of
        {From, To} when is_binary(From), is_binary(To) ->
            [#{<<"from">> => From, <<"to">> => To} | Routes0];
        _ -> Routes0
    end,
    Retries = case binary:match(Type, <<"retry">>) of
        nomatch -> Retries0;
        _ -> Retries0 + 1
    end,
    Pauses = case binary:match(Type, <<"pause">>) of
        nomatch -> Pauses0;
        _ -> Pauses0 + 1
    end,
    {States, Active, Routes, Retries, Pauses}.

event_state(Type) ->
    case {binary:match(Type, <<"started">>),
          binary:match(Type, <<"completed">>),
          binary:match(Type, <<"failed">>),
          binary:match(Type, <<"paused">>)} of
        {{_, _}, _, _, _} -> <<"running">>;
        {_, {_, _}, _, _} -> <<"completed">>;
        {_, _, {_, _}, _} -> <<"failed">>;
        {_, _, _, {_, _}} -> <<"paused">>;
        _ -> undefined
    end.

valid_id(Value) when is_binary(Value), byte_size(Value) > 0,
                          byte_size(Value) =< ?MAX_ID_BYTES ->
    unicode:characters_to_binary(Value, utf8, utf8) =:= Value;
valid_id(_) -> false.
