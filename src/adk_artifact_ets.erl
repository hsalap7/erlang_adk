%% @doc In-memory artifact service with immutable, scoped versions.
-module(adk_artifact_ets).
-behaviour(adk_artifact_service).
-behaviour(gen_server).

-export([put/5, get/4, list/2, delete/4, stop/1]).
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

-record(state, {
    table :: ets:tid(),
    counters = #{} :: map()
}).

-spec start_link(map()) -> {ok, pid()} | {error, term()}.
start_link(Config) when is_map(Config) ->
    gen_server:start_link(?MODULE, Config, []);
start_link(_Config) ->
    {error, invalid_config}.

-spec put(pid(), adk_artifact_service:scope(), binary(), binary(), map()) ->
    {ok, adk_artifact_service:artifact_meta()} | {error, term()}.
put(Handle, Scope, Name, Data, Options) ->
    safe_call(Handle, {put, Scope, Name, Data, Options}).

-spec get(pid(), adk_artifact_service:scope(), binary(),
          adk_artifact_service:selector()) ->
    {ok, adk_artifact_service:artifact()} | {error, term()}.
get(Handle, Scope, Name, Selector) ->
    safe_call(Handle, {get, Scope, Name, Selector}).

-spec list(pid(), adk_artifact_service:scope()) ->
    {ok, [adk_artifact_service:artifact_meta()]} | {error, term()}.
list(Handle, Scope) ->
    safe_call(Handle, {list, Scope}).

-spec delete(pid(), adk_artifact_service:scope(), binary(),
             adk_artifact_service:delete_selector()) -> ok | {error, term()}.
delete(Handle, Scope, Name, Selector) ->
    safe_call(Handle, {delete, Scope, Name, Selector}).

-spec stop(pid()) -> ok | {error, term()}.
stop(Handle) ->
    safe_call(Handle, stop).

%% gen_server callbacks

init(_Config) ->
    Table = ets:new(?MODULE, [ordered_set, private,
                              {read_concurrency, true}]),
    {ok, #state{table = Table}}.

handle_call({put, Scope, Name, Data, Options}, _From, State) ->
    case validate_put(Scope, Name, Data, Options) of
        {ok, MimeType, UserMetadata} ->
            CounterKey = {Scope, Name},
            Version = maps:get(CounterKey, State#state.counters, 0) + 1,
            Metadata = #{
                scope => Scope,
                name => Name,
                version => Version,
                mime_type => MimeType,
                digest => digest(Data),
                size => byte_size(Data),
                created_at => erlang:system_time(millisecond),
                metadata => UserMetadata
            },
            Artifact = Metadata#{data => Data},
            true = ets:insert(State#state.table,
                              {{Scope, Name, Version}, Artifact}),
            Counters = (State#state.counters)#{CounterKey => Version},
            {reply, {ok, Metadata}, State#state{counters = Counters}};
        {error, _} = Error ->
            {reply, Error, State}
    end;
handle_call({get, Scope, Name, Selector}, _From, State) ->
    Reply = case validate_lookup(Scope, Name, Selector) of
        ok -> lookup_artifact(State#state.table, Scope, Name, Selector);
        {error, _} = Error -> Error
    end,
    {reply, Reply, State};
handle_call({list, Scope}, _From, State) ->
    Reply = case validate_scope(Scope) of
        ok -> {ok, list_scope(State#state.table, Scope)};
        {error, _} = Error -> Error
    end,
    {reply, Reply, State};
handle_call({delete, Scope, Name, Selector}, _From, State) ->
    Reply = case validate_delete(Scope, Name, Selector) of
        ok -> delete_artifact(State#state.table, Scope, Name, Selector);
        {error, _} = Error -> Error
    end,
    {reply, Reply, State};
handle_call(stop, _From, State) ->
    {stop, normal, ok, State};
handle_call(_Request, _From, State) ->
    {reply, {error, unsupported_request}, State}.

handle_cast(_Message, State) ->
    {noreply, State}.

handle_info(_Message, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVersion, State, _Extra) ->
    {ok, State}.

safe_call(Handle, Request) when is_pid(Handle) ->
    try gen_server:call(Handle, Request, ?CALL_TIMEOUT) of
        Reply -> Reply
    catch
        exit:{timeout, _} -> {error, timeout};
        exit:{noproc, _} -> {error, unavailable};
        exit:Reason -> {error, {service_call_failed, Reason}}
    end;
safe_call(_Handle, _Request) ->
    {error, invalid_handle}.

validate_put(Scope, Name, Data, Options)
  when is_binary(Data), is_map(Options) ->
    case {validate_scope(Scope), validate_name(Name),
          validate_options(Options)} of
        {ok, ok, {ok, MimeType, Metadata}} ->
            {ok, MimeType, Metadata};
        {{error, _} = Error, _, _} -> Error;
        {_, {error, _} = Error, _} -> Error;
        {_, _, {error, _} = Error} -> Error
    end;
validate_put(_Scope, _Name, Data, _Options) when not is_binary(Data) ->
    {error, invalid_data};
validate_put(_Scope, _Name, _Data, _Options) ->
    {error, invalid_options}.

validate_lookup(Scope, Name, Selector) ->
    case {validate_scope(Scope), validate_name(Name),
          valid_selector(Selector)} of
        {ok, ok, true} -> ok;
        {{error, _} = Error, _, _} -> Error;
        {_, {error, _} = Error, _} -> Error;
        {_, _, false} -> {error, invalid_selector}
    end.

validate_delete(Scope, Name, all) ->
    case {validate_scope(Scope), validate_name(Name)} of
        {ok, ok} -> ok;
        {{error, _} = Error, _} -> Error;
        {_, {error, _} = Error} -> Error
    end;
validate_delete(Scope, Name, Selector) ->
    validate_lookup(Scope, Name, Selector).

validate_scope({app, AppName}) ->
    validate_scope_part(app_name, AppName);
validate_scope({user, AppName, UserId}) ->
    validate_scope_parts([{app_name, AppName}, {user_id, UserId}]);
validate_scope({session, AppName, UserId, SessionId}) ->
    validate_scope_parts([{app_name, AppName}, {user_id, UserId},
                          {session_id, SessionId}]);
validate_scope(_Scope) ->
    {error, invalid_scope}.

validate_scope_parts([]) -> ok;
validate_scope_parts([{Label, Value} | Rest]) ->
    case validate_scope_part(Label, Value) of
        ok -> validate_scope_parts(Rest);
        {error, _} = Error -> Error
    end.

validate_scope_part(Label, Value) when is_binary(Value), byte_size(Value) > 0 ->
    case valid_utf8(Value) andalso binary:match(Value, <<0>>) =:= nomatch of
        true -> ok;
        false -> {error, {invalid_scope_part, Label}}
    end;
validate_scope_part(Label, _Value) ->
    {error, {invalid_scope_part, Label}}.

validate_name(Name) when is_binary(Name), byte_size(Name) > 0 ->
    Parts = binary:split(Name, <<"/">>, [global]),
    ValidParts = lists:all(
                   fun(<<>>) -> false;
                      (<<".">>) -> false;
                      (<<"..">>) -> false;
                      (Part) -> binary:match(Part, <<0>>) =:= nomatch
                   end, Parts),
    case valid_utf8(Name) andalso ValidParts of
        true -> ok;
        false -> {error, invalid_name}
    end;
validate_name(_Name) ->
    {error, invalid_name}.

validate_options(Options) ->
    Unknown = maps:without([mime_type, metadata], Options),
    MimeType = maps:get(mime_type, Options,
                        <<"application/octet-stream">>),
    Metadata = maps:get(metadata, Options, #{}),
    case {map_size(Unknown), valid_mime_type(MimeType),
          json_safe(Metadata)} of
        {0, true, true} when is_map(Metadata) ->
            {ok, MimeType, Metadata};
        {Size, _, _} when Size > 0 ->
            {error, {unknown_options, maps:keys(Unknown)}};
        {_, false, _} ->
            {error, invalid_mime_type};
        _ ->
            {error, invalid_metadata}
    end.

valid_mime_type(MimeType) when is_binary(MimeType), byte_size(MimeType) > 2 ->
    valid_utf8(MimeType) andalso
    binary:match(MimeType, <<"/">>) =/= nomatch andalso
    binary:match(MimeType, <<"\r">>) =:= nomatch andalso
    binary:match(MimeType, <<"\n">>) =:= nomatch andalso
    binary:match(MimeType, <<0>>) =:= nomatch;
valid_mime_type(_) ->
    false.

valid_selector(latest) -> true;
valid_selector(Version) -> is_integer(Version) andalso Version > 0.

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
    lists:sort(
      fun(Left, Right) ->
          {maps:get(name, Left), maps:get(version, Left)} =<
          {maps:get(name, Right), maps:get(version, Right)}
      end, Artifacts).

delete_artifact(Table, Scope, Name, all) ->
    Keys = [{ArtifactScope, ArtifactName, Version}
            || {{ArtifactScope, ArtifactName, Version}, _}
                   <- ets:tab2list(Table),
               ArtifactScope =:= Scope, ArtifactName =:= Name],
    case Keys of
        [] -> {error, not_found};
        _ ->
            lists:foreach(fun(Key) -> true = ets:delete(Table, Key) end,
                          Keys),
            ok
    end;
delete_artifact(Table, Scope, Name, latest) ->
    case latest_version(Table, Scope, Name) of
        {ok, Version} -> delete_artifact(Table, Scope, Name, Version);
        error -> {error, not_found}
    end;
delete_artifact(Table, Scope, Name, Version) ->
    Key = {Scope, Name, Version},
    case ets:member(Table, Key) of
        true -> true = ets:delete(Table, Key), ok;
        false -> {error, not_found}
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

digest(Data) ->
    binary:encode_hex(crypto:hash(sha256, Data), lowercase).

valid_utf8(Value) ->
    case unicode:characters_to_binary(Value, utf8, utf8) of
        Value -> true;
        _ -> false
    end.

json_safe(Value) when is_binary(Value) -> valid_utf8(Value);
json_safe(Value) when is_integer(Value); is_float(Value) -> true;
json_safe(true) -> true;
json_safe(false) -> true;
json_safe(null) -> true;
json_safe(Value) when is_list(Value) -> lists:all(fun json_safe/1, Value);
json_safe(Value) when is_map(Value) ->
    lists:all(
      fun({Key, Item}) -> is_binary(Key) andalso valid_utf8(Key)
                         andalso json_safe(Item)
      end, maps:to_list(Value));
json_safe(_) -> false.
