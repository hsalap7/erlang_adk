%% @doc Bounded in-memory artifact service with immutable, scoped versions.
-module(adk_artifact_ets).
-behaviour(adk_artifact_service).
-behaviour(gen_server).

-export([
    capabilities/1,
    put/5, put/6,
    get/4, get/5,
    list/2,
    list_names/3,
    list_versions/4,
    delete/4, delete/5,
    stop/1
]).
-export([
    start_link/1,
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-define(CALL_TIMEOUT, 5000).
-define(DEFAULT_MAX_ARTIFACT_BYTES, 64 * 1024 * 1024).
-define(DEFAULT_MAX_TOTAL_BYTES, 512 * 1024 * 1024).
-define(DEFAULT_MAX_SCOPE_BYTES, 256 * 1024 * 1024).
-define(DEFAULT_MAX_TOTAL_ARTIFACTS, 100000).
-define(DEFAULT_MAX_SCOPE_ARTIFACTS, 25000).
-define(DEFAULT_MAX_PAGE_LIMIT, 1000).
-define(DEFAULT_LEGACY_LIST_LIMIT, 1000).

-record(state, {
    table :: ets:tid(),
    counters = #{} :: map(),
    total_bytes = 0 :: non_neg_integer(),
    total_items = 0 :: non_neg_integer(),
    scope_usage = #{} :: map(),
    max_artifact_bytes :: pos_integer(),
    max_total_bytes :: pos_integer(),
    max_scope_bytes :: pos_integer(),
    max_total_artifacts :: pos_integer(),
    max_scope_artifacts :: pos_integer(),
    max_page_limit :: pos_integer(),
    legacy_list_limit :: pos_integer()
}).

-spec start_link(map()) -> {ok, pid()} | {error, term()}.
start_link(Config) when is_map(Config) ->
    case validate_config(Config) of
        {ok, Limits} -> gen_server:start_link(?MODULE, Limits, []);
        {error, _} = Error -> Error
    end;
start_link(_Config) ->
    {error, invalid_config}.

-spec capabilities(pid()) -> {ok, map()} | {error, term()}.
capabilities(Handle) ->
    safe_call(Handle, capabilities, ?CALL_TIMEOUT).

-spec put(pid(), adk_artifact_service:scope(), binary(), binary(), map()) ->
    {ok, adk_artifact_service:artifact_meta()} | {error, term()}.
put(Handle, Scope, Name, Data, Options) ->
    put(Handle, Scope, Name, Data, Options, #{}).

-spec put(pid(), adk_artifact_service:scope(), binary(), binary(), map(),
          adk_artifact_service:call_options()) ->
    {ok, adk_artifact_service:artifact_meta()} | {error, term()}.
put(Handle, Scope, Name, Data, Options, CallOptions) ->
    timed_call(Handle,
               fun(Deadline) ->
                   {put, Scope, Name, Data, Options, Deadline}
               end, CallOptions, ?CALL_TIMEOUT).

-spec get(pid(), adk_artifact_service:scope(), binary(),
          adk_artifact_service:selector()) ->
    {ok, adk_artifact_service:artifact()} | {error, term()}.
get(Handle, Scope, Name, Selector) ->
    get(Handle, Scope, Name, Selector, #{}).

-spec get(pid(), adk_artifact_service:scope(), binary(),
          adk_artifact_service:selector(),
          adk_artifact_service:call_options()) ->
    {ok, adk_artifact_service:artifact()} | {error, term()}.
get(Handle, Scope, Name, Selector, CallOptions) ->
    timed_call(Handle,
               fun(Deadline) -> {get, Scope, Name, Selector, Deadline} end,
               CallOptions, ?CALL_TIMEOUT).

-spec list(pid(), adk_artifact_service:scope()) ->
    {ok, [adk_artifact_service:artifact_meta()]} | {error, term()}.
list(Handle, Scope) ->
    timed_call(Handle, fun(Deadline) -> {list, Scope, Deadline} end,
               #{}, ?CALL_TIMEOUT).

-spec list_names(pid(), adk_artifact_service:scope(), map()) ->
    {ok, adk_artifact_service:name_page()} | {error, term()}.
list_names(Handle, Scope, Options) ->
    timed_call(Handle,
               fun(Deadline) -> {list_names, Scope, Options, Deadline} end,
               #{}, ?CALL_TIMEOUT).

-spec list_versions(pid(), adk_artifact_service:scope(), binary(), map()) ->
    {ok, adk_artifact_service:version_page()} | {error, term()}.
list_versions(Handle, Scope, Name, Options) ->
    timed_call(Handle,
               fun(Deadline) ->
                   {list_versions, Scope, Name, Options, Deadline}
               end, #{}, ?CALL_TIMEOUT).

-spec delete(pid(), adk_artifact_service:scope(), binary(),
             adk_artifact_service:delete_selector()) -> ok | {error, term()}.
delete(Handle, Scope, Name, Selector) ->
    delete(Handle, Scope, Name, Selector, #{}).

-spec delete(pid(), adk_artifact_service:scope(), binary(),
             adk_artifact_service:delete_selector(),
             adk_artifact_service:call_options()) -> ok | {error, term()}.
delete(Handle, Scope, Name, Selector, CallOptions) ->
    timed_call(Handle,
               fun(Deadline) ->
                   {delete, Scope, Name, Selector, Deadline}
               end, CallOptions, ?CALL_TIMEOUT).

-spec stop(pid()) -> ok | {error, term()}.
stop(Handle) ->
    safe_call(Handle, stop, ?CALL_TIMEOUT).

init(Limits) ->
    Table = ets:new(?MODULE, [ordered_set, private,
                              {read_concurrency, true}]),
    {ok, #state{
        table = Table,
        max_artifact_bytes = maps:get(max_artifact_bytes, Limits),
        max_total_bytes = maps:get(max_total_bytes, Limits),
        max_scope_bytes = maps:get(max_scope_bytes, Limits),
        max_total_artifacts = maps:get(max_total_artifacts, Limits),
        max_scope_artifacts = maps:get(max_scope_artifacts, Limits),
        max_page_limit = maps:get(max_page_limit, Limits),
        legacy_list_limit = maps:get(legacy_list_limit, Limits)
    }}.

handle_call(capabilities, _From, State) ->
    {reply, {ok, capability_map(State)}, State};
handle_call({put, Scope, Name, Data, Options, Deadline}, _From, State) ->
    case request_expired(Deadline) of
        true -> {reply, {error, timeout}, State};
        false -> handle_put(Scope, Name, Data, Options, Deadline, State)
    end;
handle_call({get, Scope, Name, Selector, Deadline}, _From, State) ->
    Reply = case request_expired(Deadline) of
        true -> {error, timeout};
        false ->
            case adk_artifact_core:validate_lookup(Scope, Name, Selector) of
                ok -> lookup_artifact(State#state.table, Scope, Name, Selector);
                {error, _} = Error -> Error
            end
    end,
    {reply, Reply, State};
handle_call({list, Scope, Deadline}, _From, State) ->
    Reply = case request_expired(Deadline) of
        true -> {error, timeout};
        false -> legacy_list(Scope, State)
    end,
    {reply, Reply, State};
handle_call({list_names, Scope, Options, Deadline}, _From, State) ->
    Reply = case request_expired(Deadline) of
        true -> {error, timeout};
        false -> list_names_page(Scope, Options, State)
    end,
    {reply, Reply, State};
handle_call({list_versions, Scope, Name, Options, Deadline}, _From, State) ->
    Reply = case request_expired(Deadline) of
        true -> {error, timeout};
        false -> list_versions_page(Scope, Name, Options, State)
    end,
    {reply, Reply, State};
handle_call({delete, Scope, Name, Selector, Deadline}, _From, State) ->
    case request_expired(Deadline) of
        true -> {reply, {error, timeout}, State};
        false -> handle_delete(Scope, Name, Selector, Deadline, State)
    end;
handle_call(stop, _From, State) ->
    {stop, normal, ok, State};
handle_call(_Request, _From, State) ->
    {reply, {error, unsupported_request}, State}.

handle_cast(_Message, State) -> {noreply, State}.
handle_info(_Message, State) -> {noreply, State}.
terminate(_Reason, _State) -> ok.
code_change(_OldVersion, State, _Extra) -> {ok, State}.

handle_put(Scope, Name, Data, Options, Deadline, State) ->
    Validation = adk_artifact_core:validate_put(Scope, Name, Data, Options),
    case Validation of
        {ok, MimeType, UserMetadata} ->
            case check_quota(Scope, byte_size(Data), State) of
                ok ->
                    case request_expired(Deadline) of
                        true -> {reply, {error, timeout}, State};
                        false -> commit_put(Scope, Name, Data, MimeType,
                                            UserMetadata, State)
                    end;
                {error, _} = Error -> {reply, Error, State}
            end;
        {error, _} = Error -> {reply, Error, State}
    end.

commit_put(Scope, Name, Data, MimeType, UserMetadata, State) ->
    CounterKey = {Scope, Name},
    Version = maps:get(CounterKey, State#state.counters, 0) + 1,
    Metadata = adk_artifact_core:artifact_metadata(
                 Scope, Name, Version, Data, MimeType, UserMetadata),
    Artifact = Metadata#{data => Data},
    true = ets:insert(State#state.table,
                      {{Scope, Name, Version}, Artifact}),
    Counters = (State#state.counters)#{CounterKey => Version},
    NewState = add_usage(Scope, byte_size(Data), State),
    {reply, {ok, Metadata}, NewState#state{counters = Counters}}.

handle_delete(Scope, Name, Selector, Deadline, State) ->
    case adk_artifact_core:validate_delete(Scope, Name, Selector) of
        ok ->
            case delete_candidates(State#state.table, Scope, Name, Selector) of
                [] -> {reply, {error, not_found}, State};
                Candidates ->
                    case request_expired(Deadline) of
                        true -> {reply, {error, timeout}, State};
                        false -> commit_delete(Scope, Candidates, State)
                    end
            end;
        {error, _} = Error -> {reply, Error, State}
    end.

commit_delete(Scope, Candidates, State) ->
    Bytes = lists:sum([maps:get(size, Artifact)
                       || {_Key, Artifact} <- Candidates]),
    lists:foreach(fun({Key, _Artifact}) -> true = ets:delete(State#state.table,
                                                             Key)
                  end, Candidates),
    {reply, ok, remove_usage(Scope, length(Candidates), Bytes, State)}.

legacy_list(Scope, State) ->
    case adk_artifact_core:validate_scope(Scope) of
        ok ->
            Items = list_scope(State#state.table, Scope),
            case length(Items) =< State#state.legacy_list_limit of
                true -> {ok, Items};
                false -> {error, result_limit_exceeded}
            end;
        {error, _} = Error -> Error
    end.

list_names_page(Scope, Options, State) ->
    case {adk_artifact_core:validate_scope(Scope),
          adk_artifact_core:validate_page_options(
            Options, name, State#state.max_page_limit)} of
        {ok, {ok, Limit, Cursor}} ->
            Names = lists:usort([Name || {{ArtifactScope, Name, _}, _}
                                              <- ets:tab2list(State#state.table),
                                          ArtifactScope =:= Scope]),
            {ok, (page_names(Names, Cursor, Limit))#{scope => Scope}};
        {{error, _} = Error, _} -> Error;
        {_, {error, _} = Error} -> Error
    end.

list_versions_page(Scope, Name, Options, State) ->
    case {adk_artifact_core:validate_lookup(Scope, Name, 1),
          adk_artifact_core:validate_page_options(
            Options, version, State#state.max_page_limit)} of
        {ok, {ok, Limit, Cursor}} ->
            Items = [maps:remove(data, Artifact)
                     || {{ArtifactScope, ArtifactName, _}, Artifact}
                            <- ets:tab2list(State#state.table),
                        ArtifactScope =:= Scope, ArtifactName =:= Name],
            Sorted = lists:sort(fun metadata_less_or_equal/2, Items),
            {ok, page_versions(Sorted, Cursor, Limit)};
        {{error, _} = Error, _} -> Error;
        {_, {error, _} = Error} -> Error
    end.

page_names(Names, undefined, Limit) -> page_names_after(Names, Limit);
page_names(Names, Cursor, Limit) ->
    page_names_after(lists:dropwhile(fun(Name) -> Name =< Cursor end, Names),
                     Limit).

page_names_after(Names, Limit) ->
    {Items, More} = take_page(Names, Limit),
    Next = case More of true -> lists:last(Items); false -> undefined end,
    #{items => Items, next_cursor => Next}.

page_versions(Items, undefined, Limit) -> page_versions_after(Items, Limit);
page_versions(Items, Cursor, Limit) ->
    page_versions_after(
      lists:dropwhile(fun(Meta) -> maps:get(version, Meta) =< Cursor end,
                      Items), Limit).

page_versions_after(Items, Limit) ->
    {Page, More} = take_page(Items, Limit),
    Next = case More of
        true -> maps:get(version, lists:last(Page));
        false -> undefined
    end,
    #{items => Page, next_cursor => Next}.

take_page(Items, Limit) ->
    Candidate = lists:sublist(Items, Limit + 1),
    case length(Candidate) > Limit of
        true -> {lists:sublist(Candidate, Limit), true};
        false -> {Candidate, false}
    end.

lookup_artifact(Table, Scope, Name, latest) ->
    case latest_version(Table, Scope, Name) of
        {ok, Version} -> lookup_artifact(Table, Scope, Name, Version);
        error -> {error, not_found}
    end;
lookup_artifact(Table, Scope, Name, Version) ->
    case ets:lookup(Table, {Scope, Name, Version}) of
        [{_, Artifact}] -> {ok, Artifact};
        [] -> {error, not_found}
    end.

list_scope(Table, Scope) ->
    Artifacts = [maps:remove(data, Artifact)
                 || {{ArtifactScope, _Name, _Version}, Artifact}
                        <- ets:tab2list(Table),
                    ArtifactScope =:= Scope],
    lists:sort(fun metadata_less_or_equal/2, Artifacts).

metadata_less_or_equal(Left, Right) ->
    {maps:get(name, Left), maps:get(version, Left)} =<
    {maps:get(name, Right), maps:get(version, Right)}.

delete_candidates(Table, Scope, Name, all) ->
    [{Key, Artifact} || {Key = {ArtifactScope, ArtifactName, _}, Artifact}
                              <- ets:tab2list(Table),
                          ArtifactScope =:= Scope, ArtifactName =:= Name];
delete_candidates(Table, Scope, Name, latest) ->
    case latest_version(Table, Scope, Name) of
        {ok, Version} -> delete_candidates(Table, Scope, Name, Version);
        error -> []
    end;
delete_candidates(Table, Scope, Name, Version) ->
    Key = {Scope, Name, Version},
    case ets:lookup(Table, Key) of
        [{_, Artifact}] -> [{Key, Artifact}];
        [] -> []
    end.

latest_version(Table, Scope, Name) ->
    Versions = [Version || {{ArtifactScope, ArtifactName, Version}, _}
                              <- ets:tab2list(Table),
                           ArtifactScope =:= Scope,
                           ArtifactName =:= Name],
    case Versions of
        [] -> error;
        _ -> {ok, lists:max(Versions)}
    end.

check_quota(_Scope, Bytes, State)
  when Bytes > State#state.max_artifact_bytes ->
    {error, artifact_too_large};
check_quota(Scope, Bytes, State) ->
    #{bytes := ScopeBytes, items := ScopeItems} =
        maps:get(Scope, State#state.scope_usage, #{bytes => 0, items => 0}),
    Checks = [
        {State#state.total_bytes + Bytes =< State#state.max_total_bytes,
         max_total_bytes},
        {ScopeBytes + Bytes =< State#state.max_scope_bytes,
         max_scope_bytes},
        {State#state.total_items + 1 =< State#state.max_total_artifacts,
         max_total_artifacts},
        {ScopeItems + 1 =< State#state.max_scope_artifacts,
         max_scope_artifacts}
    ],
    first_quota_error(Checks).

first_quota_error([]) -> ok;
first_quota_error([{true, _} | Rest]) -> first_quota_error(Rest);
first_quota_error([{false, Limit} | _]) -> {error, {quota_exceeded, Limit}}.

add_usage(Scope, Bytes, State) ->
    Usage0 = maps:get(Scope, State#state.scope_usage,
                      #{bytes => 0, items => 0}),
    Usage = #{bytes => maps:get(bytes, Usage0) + Bytes,
              items => maps:get(items, Usage0) + 1},
    State#state{total_bytes = State#state.total_bytes + Bytes,
                total_items = State#state.total_items + 1,
                scope_usage = (State#state.scope_usage)#{Scope => Usage}}.

remove_usage(Scope, Count, Bytes, State) ->
    Usage0 = maps:get(Scope, State#state.scope_usage),
    Usage = #{bytes => maps:get(bytes, Usage0) - Bytes,
              items => maps:get(items, Usage0) - Count},
    ScopeUsage = case Usage of
        #{bytes := 0, items := 0} -> maps:remove(Scope, State#state.scope_usage);
        _ -> (State#state.scope_usage)#{Scope => Usage}
    end,
    State#state{total_bytes = State#state.total_bytes - Bytes,
                total_items = State#state.total_items - Count,
                scope_usage = ScopeUsage}.

capability_map(State) ->
    #{api_version => 1,
      immutable_versions => true,
      scopes => [app, user, session],
      pagination => #{max_page_limit => State#state.max_page_limit,
                      legacy_list_limit => State#state.legacy_list_limit},
      deadlines => true,
      cancellation => deadline,
      persistence => volatile,
      recovery => none,
      quotas => #{max_artifact_bytes => State#state.max_artifact_bytes,
                  max_total_bytes => State#state.max_total_bytes,
                  max_scope_bytes => State#state.max_scope_bytes,
                  max_total_artifacts => State#state.max_total_artifacts,
                  max_scope_artifacts => State#state.max_scope_artifacts},
      validation_limits => adk_artifact_core:limits()}.

validate_config(Config) ->
    Keys = [max_artifact_bytes, max_total_bytes, max_scope_bytes,
            max_total_artifacts, max_scope_artifacts, max_page_limit,
            legacy_list_limit],
    Unknown = maps:without(Keys, Config),
    Limits = #{
        max_artifact_bytes => maps:get(max_artifact_bytes, Config,
                                       ?DEFAULT_MAX_ARTIFACT_BYTES),
        max_total_bytes => maps:get(max_total_bytes, Config,
                                    ?DEFAULT_MAX_TOTAL_BYTES),
        max_scope_bytes => maps:get(max_scope_bytes, Config,
                                    ?DEFAULT_MAX_SCOPE_BYTES),
        max_total_artifacts => maps:get(max_total_artifacts, Config,
                                        ?DEFAULT_MAX_TOTAL_ARTIFACTS),
        max_scope_artifacts => maps:get(max_scope_artifacts, Config,
                                        ?DEFAULT_MAX_SCOPE_ARTIFACTS),
        max_page_limit => maps:get(max_page_limit, Config,
                                   ?DEFAULT_MAX_PAGE_LIMIT),
        legacy_list_limit => maps:get(legacy_list_limit, Config,
                                      ?DEFAULT_LEGACY_LIST_LIMIT)
    },
    case {map_size(Unknown),
          lists:all(fun({_Key, Value}) ->
                            is_integer(Value) andalso Value > 0
                    end, maps:to_list(Limits)),
          maps:get(max_artifact_bytes, Limits) =<
              maps:get(max_scope_bytes, Limits),
          maps:get(max_scope_bytes, Limits) =< maps:get(max_total_bytes, Limits),
          maps:get(max_scope_artifacts, Limits) =<
              maps:get(max_total_artifacts, Limits)} of
        {Size, _, _, _, _} when Size > 0 ->
            {error, {unknown_config, lists:sort(maps:keys(Unknown))}};
        {_, false, _, _, _} -> {error, invalid_config_limit};
        {_, _, false, _, _} -> {error, invalid_max_artifact_bytes};
        {_, _, _, false, _} -> {error, invalid_max_scope_bytes};
        {_, _, _, _, false} -> {error, invalid_max_scope_artifacts};
        {0, true, true, true, true} -> {ok, Limits}
    end.

timed_call(Handle, RequestFun, CallOptions, DefaultTimeout) ->
    case adk_artifact_core:validate_call_options(CallOptions, DefaultTimeout) of
        {ok, Timeout, Deadline} ->
            safe_call(Handle, RequestFun(Deadline), Timeout);
        {error, _} = Error -> Error
    end.

safe_call(Handle, Request, Timeout) when is_pid(Handle) ->
    try gen_server:call(Handle, Request, Timeout) of
        Reply -> Reply
    catch
        exit:{timeout, _} -> {error, timeout};
        exit:{noproc, _} -> {error, unavailable};
        exit:Reason -> {error, {service_call_failed, Reason}}
    end;
safe_call(_Handle, _Request, _Timeout) ->
    {error, invalid_handle}.

request_expired(Deadline) ->
    adk_artifact_core:deadline_expired(Deadline).
