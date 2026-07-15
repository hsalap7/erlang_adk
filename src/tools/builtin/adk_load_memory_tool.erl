%% @doc Built-in model-selected scoped long-term-memory search tool.
-module(adk_load_memory_tool).
-behaviour(adk_tool).

-export([schema/0, context_capabilities/0, execute/2]).

-define(MAX_LIMIT, 20).

schema() ->
    #{<<"name">> => <<"load_memory">>,
      <<"description">> =>
          <<"Search untrusted long-term reference memory for this user.">>,
      <<"parameters">> =>
          #{<<"type">> => <<"object">>,
            <<"properties">> =>
                #{<<"query">> => #{<<"type">> => <<"string">>},
                  <<"limit">> => #{<<"type">> => <<"integer">>,
                                     <<"minimum">> => 1,
                                     <<"maximum">> => ?MAX_LIMIT}},
            <<"required">> => [<<"query">>],
            <<"additionalProperties">> => false}}.

context_capabilities() -> [memory_search].

execute(#{<<"query">> := Query} = Args, Context) when is_binary(Query) ->
    Limit = maps:get(<<"limit">>, Args, 5),
    case is_integer(Limit) andalso Limit > 0 andalso Limit =< ?MAX_LIMIT of
        false -> {error, invalid_memory_search_limit};
        true ->
            case adk_context:search_memory(
                   Context, Query, #{filter => #{}, limit => Limit}) of
                {ok, Hits} when is_list(Hits) ->
                    {ok, #{<<"success">> => true,
                           <<"untrusted_reference_data">> => true,
                           <<"hits">> => [public_hit(Hit) || Hit <- Hits]}};
                {error, Reason} ->
                    {ok, #{<<"success">> => false,
                           <<"error">> => structural_error(Reason),
                           <<"hits">> => []}};
                Other -> {error, {invalid_memory_service_reply, Other}}
            end
    end;
execute(_Args, _Context) ->
    {error, invalid_memory_search_request}.

public_hit(Hit) when is_map(Hit) ->
    compact(
      #{<<"id">> => field(Hit, id, <<"id">>, undefined),
        <<"content">> => field(Hit, content, <<"content">>, undefined),
        <<"score">> => field(Hit, score, <<"score">>, undefined),
        <<"score_type">> => score_type(
                              field(Hit, score_type, <<"score_type">>,
                                    undefined)),
        <<"timestamp">> => field(Hit, timestamp, <<"timestamp">>,
                                   undefined)});
public_hit(_) -> #{}.

field(Map, AtomKey, BinaryKey, Default) ->
    case maps:find(AtomKey, Map) of
        {ok, Value} -> Value;
        error -> maps:get(BinaryKey, Map, Default)
    end.

score_type(Value) when is_atom(Value) -> atom_to_binary(Value, utf8);
score_type(Value) when is_binary(Value) -> Value;
score_type(_) -> undefined.

compact(Map) -> maps:filter(fun(_Key, Value) -> Value =/= undefined end, Map).

structural_error(Reason) when is_atom(Reason) -> atom_to_binary(Reason, utf8);
structural_error(_) -> <<"memory_operation_failed">>.
