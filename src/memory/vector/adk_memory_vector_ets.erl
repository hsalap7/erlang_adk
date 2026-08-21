%% @doc Bounded in-memory reference implementation for vector and hybrid
%% memory search. It is intentionally local and volatile; managed indexes can
%% implement the same contracts without becoming runtime dependencies.
-module(adk_memory_vector_ets).
-behaviour(gen_server).
-behaviour(adk_memory_vector_adapter).
-behaviour(adk_memory_hybrid_adapter).

-export([start_link/1, stop/1, capabilities/1, upsert/4,
         vector_search/4, hybrid_search/4, delete_scope/2, status/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-record(state, {table, limits, dimensions = undefined,
                entries = 0, bytes = 0}).

-define(CALL_TIMEOUT, 5000).

start_link(Config) when is_map(Config) ->
    case compile_config(Config) of
        {ok, Limits} -> gen_server:start_link(?MODULE, Limits, []);
        {error, _} = Error -> Error
    end;
start_link(_) -> {error, invalid_vector_memory_config}.

stop(Pid) -> safe_call(Pid, stop).
capabilities(Pid) -> safe_call(Pid, capabilities).
status(Pid) -> safe_call(Pid, status).
upsert(Pid, Scope, Documents, Options) ->
    safe_call(Pid, {upsert, Scope, Documents, Options}).
vector_search(Pid, Scope, Vector, Options) ->
    safe_call(Pid, {vector_search, Scope, Vector, Options}).
hybrid_search(Pid, Scope, Query, Options) ->
    safe_call(Pid, {hybrid_search, Scope, Query, Options}).
delete_scope(Pid, Scope) -> safe_call(Pid, {delete_scope, Scope}).

init(Limits) ->
    Table = ets:new(?MODULE, [set, private, {read_concurrency, true}]),
    {ok, #state{table = Table, limits = Limits}}.

handle_call(capabilities, _From, State) ->
    {reply, #{contract_version => 1,
              scope => app_user,
              durable => false,
              vector_metric => cosine_similarity,
              hybrid => weighted_lexical_vector,
              dimensions => State#state.dimensions,
              limits => State#state.limits}, State};
handle_call(status, _From, State) ->
    {reply, #{entries => State#state.entries,
              bytes => State#state.bytes,
              dimensions => State#state.dimensions}, State};
handle_call({upsert, Scope, Documents, Options}, _From, State) ->
    case prepare_documents(Scope, Documents, Options, State) of
        {ok, Prepared, Dimensions} ->
            case commit_documents(Prepared, Dimensions, State) of
                {ok, Result, Next} -> {reply, {ok, Result}, Next};
                {error, _} = Error -> {reply, Error, State}
            end;
        {error, _} = Error -> {reply, Error, State}
    end;
handle_call({vector_search, Scope, Vector, Options}, _From, State) ->
    {reply, search_vector(Scope, Vector, Options, State), State};
handle_call({hybrid_search, Scope, Query, Options}, _From, State) ->
    {reply, search_hybrid(Scope, Query, Options, State), State};
handle_call({delete_scope, Scope}, _From, State) ->
    case adk_memory_contract:validate_scope(Scope) of
        {ok, Canonical} ->
            Matches = [{Key, Doc} || {Key = {Seen, _}, Doc}
                                        <- ets:tab2list(State#state.table),
                                    Seen =:= Canonical],
            lists:foreach(fun({Key, _}) -> ets:delete(State#state.table, Key)
                          end, Matches),
            RemovedBytes = lists:sum([maps:get(storage_bytes, Doc)
                                      || {_Key, Doc} <- Matches]),
            Next = State#state{
                     entries = State#state.entries - length(Matches),
                     bytes = State#state.bytes - RemovedBytes},
            {reply, {ok, length(Matches)}, maybe_clear_dimensions(Next)};
        {error, _} = Error -> {reply, Error, State}
    end;
handle_call(stop, _From, State) -> {stop, normal, ok, State};
handle_call(_Request, _From, State) ->
    {reply, {error, unsupported_vector_memory_operation}, State}.

handle_cast(_Message, State) -> {noreply, State}.
handle_info(_Message, State) -> {noreply, State}.
terminate(_Reason, _State) -> ok.
code_change(_Old, State, _Extra) -> {ok, State}.

compile_config(Config) ->
    Defaults = #{max_dimensions => 4096,
                 max_entries => 10000,
                 max_total_bytes => 67108864,
                 max_content_bytes => 65536,
                 max_metadata_bytes => 16384,
                 max_batch => 256,
                 max_results => 100,
                 max_result_bytes => 1048576},
    Unknown = lists:sort(maps:keys(maps:without(maps:keys(Defaults), Config))),
    Limits = maps:merge(Defaults, Config),
    Checks = [{max_dimensions, 65536}, {max_entries, 1000000},
              {max_total_bytes, 1073741824},
              {max_content_bytes, 1048576},
              {max_metadata_bytes, 262144}, {max_batch, 10000},
              {max_results, 1000}, {max_result_bytes, 16777216}],
    case {Unknown, lists:all(fun({Key, Max}) ->
                 Value = maps:get(Key, Limits),
                 is_integer(Value) andalso Value > 0 andalso Value =< Max
             end, Checks)} of
        {[], true} -> {ok, Limits};
        {[_ | _], _} ->
            {error, {invalid_vector_memory_config,
                     {unknown_keys, Unknown}}};
        _ -> {error, invalid_vector_memory_limit}
    end.

prepare_documents(Scope0, Documents, Options, State) when is_map(Options) ->
    Unknown = lists:sort(maps:keys(maps:without([create_only], Options))),
    CreateOnly = maps:get(create_only, Options, false),
    case {adk_memory_contract:validate_scope(Scope0), Unknown,
          is_boolean(CreateOnly), bounded_list(
                                    Documents,
                                    maps:get(max_batch,
                                             State#state.limits))} of
        {{ok, Scope}, [], true, {ok, Count}} when Count > 0 ->
            prepare_document_list(Documents, Scope, CreateOnly, State,
                                  #{}, [], State#state.dimensions);
        {{error, _} = Error, _, _, _} -> Error;
        {_, [_ | _], _, _} ->
            {error, {invalid_vector_memory_options,
                     {unknown_keys, Unknown}}};
        {_, _, false, _} -> {error, invalid_vector_memory_create_only};
        {_, _, _, {ok, 0}} -> {error, empty_vector_memory_documents};
        {_, _, _, {error, _} = Error} -> Error
    end;
prepare_documents(_, _, _, _) ->
    {error, invalid_vector_memory_request}.

prepare_document_list([], _Scope, _CreateOnly, _State, _Seen, Acc, Dim) ->
    {ok, lists:reverse(Acc), Dim};
prepare_document_list([Doc | Rest], Scope, CreateOnly, State, Seen, Acc, Dim0)
  when is_map(Doc) ->
    Unknown = lists:sort(maps:keys(
                           maps:without([id, content, vector, metadata], Doc))),
    Id = maps:get(id, Doc, undefined),
    Content = maps:get(content, Doc, undefined),
    Vector = maps:get(vector, Doc, undefined),
    Metadata = maps:get(metadata, Doc, #{}),
    case {Unknown, bounded_binary(Id, 512),
          validate_vector(Vector, Dim0, State#state.limits),
          normalize_document(Scope, Id, Content, Metadata,
                             State#state.limits),
          maps:is_key(Id, Seen)} of
        {[], ok, {ok, Dim}, {ok, Base}, false} ->
            Key = {Scope, Id},
            case CreateOnly andalso
                 ets:member(State#state.table, Key) of
                true -> {error, {vector_memory_entry_exists, Id}};
                false ->
                    Prepared0 = Base#{id => Id, scope => Scope,
                                      vector => [to_float(V) || V <- Vector]},
                    Bytes = byte_size(term_to_binary(
                                        Prepared0, [deterministic])),
                    Prepared = Prepared0#{storage_bytes => Bytes},
                    prepare_document_list(Rest, Scope, CreateOnly, State,
                                          Seen#{Id => true},
                                          [Prepared | Acc], Dim)
            end;
        {[_ | _], _, _, _, _} ->
            {error, {invalid_vector_memory_document,
                     {unknown_keys, Unknown}}};
        {_, {error, _}, _, _, _} ->
            {error, invalid_vector_memory_id};
        {_, _, {error, _} = Error, _, _} -> Error;
        {_, _, _, {error, _} = Error, _} -> Error;
        {_, _, _, _, true} ->
            {error, {duplicate_vector_memory_id, Id}}
    end;
prepare_document_list(_, _, _, _, _, _, _) ->
    {error, invalid_vector_memory_document}.

normalize_document(Scope, Id, Content, Metadata, Limits) ->
    ContractConfig = #{max_content_bytes => maps:get(max_content_bytes, Limits),
                       max_metadata_bytes => maps:get(max_metadata_bytes, Limits),
                       max_result_bytes => maps:get(max_content_bytes, Limits)},
    case adk_memory_contract:compile_config(ContractConfig) of
        {ok, ContractLimits} ->
            case adk_memory_contract:prepare_entry(
                   Scope, #{content => Content, metadata => Metadata},
                   #{idempotency_key => Id}, ContractLimits) of
                {ok, Entry} ->
                    {ok, #{content => maps:get(content, Entry),
                           metadata => maps:get(metadata, Entry)}};
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end.

validate_vector(Vector, Dim0, Limits) when is_list(Vector) ->
    Dim = length(Vector),
    Max = maps:get(max_dimensions, Limits),
    case Dim > 0 andalso Dim =< Max andalso
         (Dim0 =:= undefined orelse Dim0 =:= Dim) andalso
         lists:all(fun finite_number/1, Vector) andalso
         magnitude(Vector) > 0.0 of
        true -> {ok, Dim};
        false -> {error, invalid_vector_memory_vector}
    end;
validate_vector(_, _, _) -> {error, invalid_vector_memory_vector}.

commit_documents(Documents, Dimensions, State) ->
    {DeltaCount, DeltaBytes, Added, Replaced} = lists:foldl(
      fun(Doc, {CountAcc, BytesAcc, AddedAcc, ReplacedAcc}) ->
          Key = {maps:get(scope, Doc), maps:get(id, Doc)},
          case ets:lookup(State#state.table, Key) of
              [] -> {CountAcc + 1,
                     BytesAcc + maps:get(storage_bytes, Doc),
                     AddedAcc + 1, ReplacedAcc};
              [{Key, Existing}] ->
                  {CountAcc,
                   BytesAcc + maps:get(storage_bytes, Doc)
                       - maps:get(storage_bytes, Existing),
                   AddedAcc, ReplacedAcc + 1}
          end
      end, {0, 0, 0, 0}, Documents),
    NewCount = State#state.entries + DeltaCount,
    NewBytes = State#state.bytes + DeltaBytes,
    case NewCount =< maps:get(max_entries, State#state.limits) andalso
         NewBytes =< maps:get(max_total_bytes, State#state.limits) of
        true ->
            true = ets:insert(State#state.table,
                              [{{maps:get(scope, Doc), maps:get(id, Doc)}, Doc}
                               || Doc <- Documents]),
            {ok, #{added => Added, replaced => Replaced},
             State#state{dimensions = Dimensions,
                         entries = NewCount, bytes = NewBytes}};
        false -> {error, vector_memory_capacity_exceeded}
    end.

search_vector(Scope0, Vector, Options, State) ->
    case prepare_search(Scope0, Vector, Options, State) of
        {ok, Scope, QueryVector, Filter, Limit} ->
            Hits = [public_hit(Doc,
                               cosine(QueryVector, maps:get(vector, Doc)),
                               cosine_similarity)
                    || {{SeenScope, _}, Doc} <- ets:tab2list(State#state.table),
                       SeenScope =:= Scope,
                       adk_memory_contract:metadata_matches(
                         maps:get(metadata, Doc), Filter)],
            {ok, bound_hits(sort_hits(Hits), Limit, State#state.limits)};
        {error, _} = Error -> Error
    end.

search_hybrid(Scope0, Query, Options, State)
  when is_map(Query), is_map(Options) ->
    UnknownQuery = lists:sort(maps:keys(
                                maps:without([text, vector], Query))),
    Text = maps:get(text, Query, undefined),
    Vector = maps:get(vector, Query, undefined),
    case {UnknownQuery, bounded_binary(Text,
                                       maps:get(max_content_bytes,
                                                State#state.limits)),
          prepare_hybrid_options(Options, State#state.limits),
          prepare_search(Scope0, Vector,
                         maps:with([filter, limit], Options), State)} of
        {[], ok, {ok, VectorWeight, LexicalWeight},
         {ok, Scope, QueryVector, Filter, Limit}} ->
            QueryTokens = tokens(Text),
            Hits = [begin
                VectorScore = cosine(QueryVector, maps:get(vector, Doc)),
                LexicalScore = lexical_score(
                                 QueryTokens,
                                 tokens(maps:get(content, Doc))),
                Score = VectorWeight * VectorScore +
                        LexicalWeight * LexicalScore,
                (public_hit(Doc, Score, hybrid))#{
                    components => #{vector => VectorScore,
                                    lexical => LexicalScore}}
            end || {{SeenScope, _}, Doc} <- ets:tab2list(State#state.table),
                   SeenScope =:= Scope,
                   adk_memory_contract:metadata_matches(
                     maps:get(metadata, Doc), Filter)],
            {ok, bound_hits(sort_hits(Hits), Limit, State#state.limits)};
        {[_ | _], _, _, _} ->
            {error, {invalid_hybrid_memory_query,
                     {unknown_keys, UnknownQuery}}};
        {_, {error, _}, _, _} -> {error, invalid_hybrid_memory_text};
        {_, _, {error, _} = Error, _} -> Error;
        {_, _, _, {error, _} = Error} -> Error
    end;
search_hybrid(_, _, _, _) -> {error, invalid_hybrid_memory_query}.

prepare_search(Scope0, Vector, Options, State) when is_map(Options) ->
    Unknown = lists:sort(maps:keys(maps:without([filter, limit], Options))),
    Limit = maps:get(limit, Options, maps:get(max_results, State#state.limits)),
    Filter = maps:get(filter, Options, #{}),
    case {adk_memory_contract:validate_scope(Scope0), Unknown,
          validate_vector(Vector, State#state.dimensions, State#state.limits),
          normalize_filter(Filter, State#state.limits),
          is_integer(Limit) andalso Limit > 0 andalso
              Limit =< maps:get(max_results, State#state.limits)} of
        {{ok, Scope}, [], {ok, _}, {ok, SafeFilter}, true} ->
            {ok, Scope, [to_float(V) || V <- Vector], SafeFilter, Limit};
        {{error, _} = Error, _, _, _, _} -> Error;
        {_, [_ | _], _, _, _} ->
            {error, {invalid_vector_memory_options,
                     {unknown_keys, Unknown}}};
        {_, _, {error, _} = Error, _, _} -> Error;
        {_, _, _, {error, _} = Error, _} -> Error;
        _ -> {error, invalid_vector_memory_limit}
    end;
prepare_search(_, _, _, _) -> {error, invalid_vector_memory_options}.

prepare_hybrid_options(Options, Limits) when is_map(Options) ->
    Unknown = lists:sort(maps:keys(maps:without(
                     [filter, limit, vector_weight, lexical_weight], Options))),
    VW = maps:get(vector_weight, Options, 0.7),
    LW = maps:get(lexical_weight, Options, 0.3),
    case {Unknown, valid_weight(VW), valid_weight(LW), VW + LW > 0,
          maps:get(limit, Options, 1) =< maps:get(max_results, Limits)} of
        {[], true, true, true, true} ->
            Sum = VW + LW,
            {ok, VW / Sum, LW / Sum};
        {[_ | _], _, _, _, _} ->
            {error, {invalid_hybrid_memory_options,
                     {unknown_keys, Unknown}}};
        _ -> {error, invalid_hybrid_memory_weights}
    end.

normalize_filter(Filter, Limits) when is_map(Filter) ->
    ContractConfig = #{max_metadata_bytes => maps:get(max_metadata_bytes, Limits),
                       max_content_bytes => maps:get(max_content_bytes, Limits),
                       max_result_bytes => maps:get(max_content_bytes, Limits)},
    case adk_memory_contract:compile_config(ContractConfig) of
        {ok, ContractLimits} ->
            case adk_memory_contract:prepare_search(
                   {user, <<"filter">>, <<"filter">>}, <<"filter">>,
                   #{filter => Filter, limit => 1}, ContractLimits) of
                {ok, _, _, Safe, _} -> {ok, Safe};
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end;
normalize_filter(_, _) -> {error, invalid_vector_memory_filter}.

public_hit(Doc, Score, Type) ->
    #{id => maps:get(id, Doc), content => maps:get(content, Doc),
      metadata => maps:get(metadata, Doc), score => Score,
      score_type => Type}.

sort_hits(Hits) ->
    lists:sort(fun(A, B) ->
        {-maps:get(score, A), maps:get(id, A)} =<
        {-maps:get(score, B), maps:get(id, B)}
    end, Hits).

bound_hits(Hits, Limit, Limits) ->
    bound_hits(Hits, Limit, maps:get(max_result_bytes, Limits), 0, []).
bound_hits(_, 0, _Max, _Bytes, Acc) -> lists:reverse(Acc);
bound_hits([], _Limit, _Max, _Bytes, Acc) -> lists:reverse(Acc);
bound_hits([Hit | Rest], Limit, Max, Bytes, Acc) ->
    Size = byte_size(term_to_binary(Hit, [deterministic])),
    case Bytes + Size =< Max of
        true -> bound_hits(Rest, Limit - 1, Max, Bytes + Size, [Hit | Acc]);
        false -> lists:reverse(Acc)
    end.

cosine(A, B) ->
    Dot = lists:sum([X * Y || {X, Y} <- lists:zip(A, B)]),
    Dot / (magnitude(A) * magnitude(B)).

magnitude(Vector) ->
    math:sqrt(lists:sum([to_float(V) * to_float(V) || V <- Vector])).

tokens(Text) ->
    lists:usort(re:split(string:lowercase(Text),
                          <<"[^\\p{L}\\p{N}_]+">>,
                          [unicode, {return, binary}, trim])).

lexical_score([], _) -> 0.0;
lexical_score(Query, Content) ->
    length([Token || Token <- Query, lists:member(Token, Content)]) /
        length(Query).

valid_weight(Value) when is_integer(Value) ->
    Value >= 0 andalso Value =< 1000000;
valid_weight(Value) when is_float(Value) ->
    Value =:= Value andalso Value >= 0 andalso Value =< 1.0e6;
valid_weight(_) -> false.

%% Cosine similarity squares and multiplies components. Keep accepted values
%% comfortably below the IEEE-754 overflow boundary so hostile bignums or
%% nominally finite floats cannot crash the owning gen_server.
finite_number(Value) when is_integer(Value) ->
    abs(Value) =< trunc(1.0e100);
finite_number(Value) when is_float(Value) ->
    Value =:= Value andalso abs(Value) =< 1.0e100;
finite_number(_) -> false.

to_float(Value) when is_integer(Value) -> float(Value);
to_float(Value) -> Value.

bounded_list(List, Max) -> bounded_list(List, Max, 0).
bounded_list([], _Max, Count) -> {ok, Count};
bounded_list([_ | _], Max, Count) when Count >= Max ->
    {error, vector_memory_batch_limit_exceeded};
bounded_list([_ | Rest], Max, Count) -> bounded_list(Rest, Max, Count + 1);
bounded_list(_, _, _) -> {error, invalid_vector_memory_documents}.

bounded_binary(Value, Max) when is_binary(Value) ->
    Size = byte_size(Value),
    case Size > 0 andalso Size =< Max andalso
         unicode:characters_to_binary(Value, utf8, utf8) =:= Value andalso
         binary:match(Value, <<0>>) =:= nomatch of
        true -> ok;
        false -> {error, invalid_or_out_of_bounds}
    end;
bounded_binary(_, _) -> {error, expected_binary}.

maybe_clear_dimensions(#state{entries = 0} = State) ->
    State#state{dimensions = undefined};
maybe_clear_dimensions(State) -> State.

safe_call(Pid, Request) when is_pid(Pid) ->
    try gen_server:call(Pid, Request, ?CALL_TIMEOUT) of
        Reply -> Reply
    catch
        exit:{timeout, _} -> {error, vector_memory_timeout};
        exit:_ -> {error, vector_memory_unavailable}
    end;
safe_call(_, _) -> {error, invalid_vector_memory_handle}.
