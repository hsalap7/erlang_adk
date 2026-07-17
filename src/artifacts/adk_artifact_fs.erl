%% @doc Durable filesystem artifact service with atomic publication.
%%
%% Logical scope and artifact names are never used as path components. A
%% durable reservation allocates each version. Data and metadata are written
%% and synced under private staging names; an atomic metadata rename is the
%% publication point, so readers never observe partially written metadata.
-module(adk_artifact_fs).
-behaviour(adk_artifact_service).
-behaviour(gen_server).

-include_lib("kernel/include/file.hrl").

-export([
    capabilities/1,
    put/5, put/6,
    get/4, get/5,
    list/2,
    list_names/3,
    list_versions/4,
    delete/4, delete/5,
    repair/1, repair/2,
    stop/1
]).
-export([start_link/1, init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(CALL_TIMEOUT, 30000).
-define(DEFAULT_MAX_ARTIFACT_BYTES, 64 * 1024 * 1024).
-define(DEFAULT_MAX_PAGE_LIMIT, 1000).
-define(DEFAULT_LEGACY_LIST_LIMIT, 1000).
-define(DEFAULT_MAX_SCAN_ENTRIES, 10000).
-define(DEFAULT_RECOVERY_GRACE_MS, 300000).
-define(MAX_METADATA_FILE_BYTES, 65536).
-define(MAX_RESERVATION_ATTEMPTS, 1024).

-record(state, {
    root :: file:filename_all(),
    max_artifact_bytes :: pos_integer(),
    max_page_limit :: pos_integer(),
    legacy_list_limit :: pos_integer(),
    max_scan_entries :: pos_integer(),
    recovery_grace_ms :: non_neg_integer()
}).

-spec start_link(map()) -> {ok, pid()} | {error, term()}.
start_link(Config) when is_map(Config) ->
    case prepare_config(Config) of
        {ok, Prepared} -> gen_server:start_link(?MODULE, Prepared, []);
        {error, _} = Error -> Error
    end;
start_link(_Config) -> {error, invalid_config}.

-spec capabilities(pid()) -> {ok, map()} | {error, term()}.
capabilities(Handle) -> safe_call(Handle, capabilities, ?CALL_TIMEOUT).

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

-spec repair(pid()) -> {ok, map()} | {error, term()}.
repair(Handle) -> repair(Handle, #{}).

-spec repair(pid(), map()) -> {ok, map()} | {error, term()}.
repair(Handle, Options) ->
    safe_call(Handle, {repair, Options}, ?CALL_TIMEOUT).

-spec stop(pid()) -> ok | {error, term()}.
stop(Handle) -> safe_call(Handle, stop, ?CALL_TIMEOUT).

init(Prepared) ->
    {ok, #state{
        root = maps:get(root, Prepared),
        max_artifact_bytes = maps:get(max_artifact_bytes, Prepared),
        max_page_limit = maps:get(max_page_limit, Prepared),
        legacy_list_limit = maps:get(legacy_list_limit, Prepared),
        max_scan_entries = maps:get(max_scan_entries, Prepared),
        recovery_grace_ms = maps:get(recovery_grace_ms, Prepared)
    }}.

handle_call(capabilities, _From, State) ->
    {reply, {ok, capability_map(State)}, State};
handle_call({put, Scope, Name, Data, Options, Deadline}, _From, State) ->
    Reply = case request_expired(Deadline) of
        true -> {error, timeout};
        false -> handle_put(Scope, Name, Data, Options, Deadline, State)
    end,
    {reply, Reply, State};
handle_call({get, Scope, Name, Selector, Deadline}, _From, State) ->
    Reply = case request_expired(Deadline) of
        true -> {error, timeout};
        false ->
            case adk_artifact_core:validate_lookup(Scope, Name, Selector) of
                ok -> get_artifact(State#state.root, Scope, Name, Selector,
                                   State#state.max_artifact_bytes,
                                   State#state.max_scan_entries);
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
    Reply = case request_expired(Deadline) of
        true -> {error, timeout};
        false ->
            case adk_artifact_core:validate_delete(Scope, Name, Selector) of
                ok -> delete_artifact(State#state.root, Scope, Name, Selector,
                                      Deadline, State#state.max_scan_entries);
                {error, _} = Error -> Error
            end
    end,
    {reply, Reply, State};
handle_call({repair, Options}, _From, State) ->
    Reply = case validate_repair_options(Options, State) of
        {ok, Limit, MinAgeMs} -> repair_root(State#state.root, Limit, MinAgeMs,
                                             State#state.max_scan_entries);
        {error, _} = Error -> Error
    end,
    {reply, Reply, State};
handle_call(stop, _From, State) -> {stop, normal, ok, State};
handle_call(_Request, _From, State) ->
    {reply, {error, unsupported_request}, State}.

handle_cast(_Message, State) -> {noreply, State}.
handle_info(_Message, State) -> {noreply, State}.
terminate(_Reason, _State) -> ok.
code_change(_OldVersion, State, _Extra) -> {ok, State}.

prepare_config(Config) ->
    case validate_config(Config) of
        {ok, Prepared0} ->
            Root = maps:get(root, Prepared0),
            case ensure_private_directory(Root) of
                ok ->
                    StorageRoot = filename:join(Root, "v1"),
                    case ensure_private_directory(StorageRoot) of
                        ok -> {ok, Prepared0#{root => StorageRoot}};
                        {error, _} = Error -> Error
                    end;
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end.

validate_config(Config) ->
    Keys = [root, max_artifact_bytes, max_page_limit, legacy_list_limit,
            max_scan_entries, recovery_grace_ms],
    Unknown = maps:without(Keys, Config),
    RootResult = normalize_root(maps:get(root, Config, undefined)),
    Values = #{
        max_artifact_bytes => maps:get(max_artifact_bytes, Config,
                                       ?DEFAULT_MAX_ARTIFACT_BYTES),
        max_page_limit => maps:get(max_page_limit, Config,
                                   ?DEFAULT_MAX_PAGE_LIMIT),
        legacy_list_limit => maps:get(legacy_list_limit, Config,
                                      ?DEFAULT_LEGACY_LIST_LIMIT),
        max_scan_entries => maps:get(max_scan_entries, Config,
                                     ?DEFAULT_MAX_SCAN_ENTRIES),
        recovery_grace_ms => maps:get(recovery_grace_ms, Config,
                                      ?DEFAULT_RECOVERY_GRACE_MS)
    },
    PositiveKeys = [max_artifact_bytes, max_page_limit, legacy_list_limit,
                    max_scan_entries],
    Positive = lists:all(fun(Key) ->
                                 Value = maps:get(Key, Values),
                                 is_integer(Value) andalso Value > 0
                         end, PositiveKeys),
    Grace = maps:get(recovery_grace_ms, Values),
    case {map_size(Unknown), RootResult, Positive,
          is_integer(Grace) andalso Grace >= 0,
          maps:get(max_scan_entries, Values) >= 3,
          maps:get(max_page_limit, Values) =<
              maps:get(max_scan_entries, Values),
          maps:get(legacy_list_limit, Values) =<
              maps:get(max_scan_entries, Values)} of
        {Size, _, _, _, _, _, _} when Size > 0 ->
            {error, {unknown_config, lists:sort(maps:keys(Unknown))}};
        {_, {error, _} = Error, _, _, _, _, _} -> Error;
        {_, _, false, _, _, _, _} -> {error, invalid_config_limit};
        {_, _, _, false, _, _, _} ->
            {error, invalid_recovery_grace_ms};
        {_, _, _, _, false, _, _} -> {error, invalid_max_scan_entries};
        {_, _, _, _, _, false, _} -> {error, invalid_max_page_limit};
        {_, _, _, _, _, _, false} ->
            {error, invalid_legacy_list_limit};
        {0, {ok, Root}, true, true, true, true, true} ->
            {ok, Values#{root => Root}}
    end.

normalize_root(undefined) -> {error, missing_root};
normalize_root(Root) when is_binary(Root), byte_size(Root) > 0 ->
    case valid_utf8(Root) andalso binary:match(Root, <<0>>) =:= nomatch of
        true -> {ok, filename:absname(binary_to_list(Root))};
        false -> {error, invalid_root}
    end;
normalize_root(Root) when is_list(Root), Root =/= [] ->
    try unicode:characters_to_binary(Root) of
        Binary -> normalize_root(Binary)
    catch _:_ -> {error, invalid_root}
    end;
normalize_root(_Root) -> {error, invalid_root}.

ensure_private_directory(Path) ->
    case filelib:ensure_dir(filename:join(Path, ".adk-write-probe")) of
        ok ->
            case file:read_link_info(Path) of
                {ok, #file_info{type = directory}} -> ok;
                {ok, #file_info{type = symlink}} ->
                    {error, {unsafe_artifact_directory, Path, symlink}};
                {ok, #file_info{type = Type}} ->
                    {error, {invalid_artifact_directory, Path, Type}};
                {error, Reason} ->
                    {error, {artifact_directory_unavailable, Path, Reason}}
            end;
        {error, Reason} ->
            {error, {artifact_directory_unavailable, Path, Reason}}
    end.

handle_put(Scope, Name, Data, Options, Deadline, State) ->
    case adk_artifact_core:validate_put(Scope, Name, Data, Options) of
        {ok, _MimeType, _Metadata}
          when byte_size(Data) > State#state.max_artifact_bytes ->
            {error, artifact_too_large};
        {ok, MimeType, UserMetadata} ->
            put_artifact(State#state.root, Scope, Name, Data, MimeType,
                         UserMetadata, Deadline, State#state.max_scan_entries);
        {error, _} = Error -> Error
    end.

put_artifact(Root, Scope, Name, Data, MimeType, UserMetadata, Deadline,
             MaxScan) ->
    NameDir = name_directory(Root, Scope, Name),
    case ensure_generated_directories(Root, Scope, NameDir, MaxScan) of
        ok ->
            case reserve_version(NameDir, ?MAX_RESERVATION_ATTEMPTS,
                                 MaxScan, Deadline) of
                {ok, Version} ->
                    Metadata = adk_artifact_core:artifact_metadata(
                                 Scope, Name, Version, Data, MimeType,
                                 UserMetadata),
                    persist_artifact(NameDir, Version, Data, Metadata,
                                     Deadline);
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end.

ensure_generated_directories(Root, Scope, NameDir, MaxScan) ->
    ScopesRoot = filename:join(Root, "scopes"),
    ScopeDir = scope_directory(Root, Scope),
    NamesRoot = filename:join(ScopeDir, "names"),
    case ensure_directories([ScopesRoot]) of
        ok ->
            case ensure_capacity_directory(
                   ScopesRoot, filename:basename(ScopeDir), scope,
                   MaxScan) of
                ok ->
                    case ensure_directories([NamesRoot]) of
                        ok -> ensure_capacity_directory(
                                NamesRoot, filename:basename(NameDir), name,
                                MaxScan);
                        {error, _} = Error -> Error
                    end;
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end.

ensure_directories([]) -> ok;
ensure_directories([Path | Rest]) ->
    case ensure_private_directory(Path) of
        ok -> ensure_directories(Rest);
        {error, _} = Error -> Error
    end.

ensure_capacity_directory(Parent, Hash, Kind, MaxScan) ->
    Directory = filename:join(Parent, Hash),
    case file:read_link_info(Directory) of
        {ok, #file_info{type = directory}} -> ok;
        {ok, #file_info{type = symlink}} ->
            {error, {unsafe_artifact_directory, Directory, symlink}};
        {ok, #file_info{type = Type}} ->
            {error, {invalid_artifact_directory, Directory, Type}};
        {error, enoent} ->
            reserve_capacity_directory(
              Parent, Directory, Hash, Kind, MaxScan,
              ?MAX_RESERVATION_ATTEMPTS);
        {error, Reason} ->
            {error, {artifact_directory_unavailable, Directory, Reason}}
    end.

reserve_capacity_directory(_Parent, _Directory, _Hash, Kind, _MaxScan, 0) ->
    {error, capacity_reservation_exhausted(Kind)};
reserve_capacity_directory(Parent, Directory, Hash, Kind, MaxScan,
                           Attempts) ->
    case bounded_list_dir(Parent, MaxScan) of
        {ok, Files} ->
            Prefix = capacity_slot_prefix(Kind),
            Capacity = MaxScan div 2,
            Slots = capacity_slots(Parent, Files, Prefix, []),
            case matching_capacity_slot(Hash, Slots) of
                true -> ensure_reserved_directory(Directory);
                false ->
                    DirectoryCount = length(
                      [File || File <- Files,
                               is_hash_directory(Parent, File)]),
                    LogicalCount = erlang:max(DirectoryCount,
                                              length(Slots)),
                    case LogicalCount >= Capacity
                         orelse length(Files) > MaxScan - 2 of
                        true -> {error, capacity_reached(Kind)};
                        false ->
                            SlotNumbers = [Number || {Number, _} <- Slots],
                            Number = first_free_slot(
                                       1, Capacity, SlotNumbers),
                            SlotPath = filename:join(
                                         Parent,
                                         Prefix ++ integer_to_list(Number)
                                         ++ ".reserve"),
                            case file:write_file(
                                   SlotPath, list_to_binary(Hash),
                                   [binary, exclusive, sync]) of
                                ok -> ensure_reserved_directory(Directory);
                                {error, eexist} ->
                                    reserve_capacity_directory(
                                      Parent, Directory, Hash, Kind, MaxScan,
                                      Attempts - 1);
                                {error, Reason} ->
                                    {error,
                                     {capacity_reservation_failed(
                                        Kind), Reason}}
                            end
                    end
            end;
        {error, scan_limit_exceeded} -> {error, capacity_reached(Kind)};
        {error, Reason} ->
            {error, {artifact_directory_unavailable, Parent, Reason}}
    end.

ensure_reserved_directory(Directory) ->
    case file:make_dir(Directory) of
        ok -> ok;
        {error, eexist} -> ensure_private_directory(Directory);
        {error, Reason} ->
            {error, {artifact_directory_unavailable, Directory, Reason}}
    end.

capacity_slots(_Parent, [], _Prefix, Acc) -> Acc;
capacity_slots(Parent, [File | Rest], Prefix, Acc) ->
    case capacity_slot_number(File, Prefix) of
        {ok, Number} ->
            Path = filename:join(Parent, File),
            Value = case read_bounded_file(Path, 64) of
                {ok, Hash} when byte_size(Hash) =:= 64 -> Hash;
                _ -> <<>>
            end,
            capacity_slots(Parent, Rest, Prefix,
                           [{Number, Value} | Acc]);
        error -> capacity_slots(Parent, Rest, Prefix, Acc)
    end.

matching_capacity_slot(Hash, Slots) ->
    HashBinary = list_to_binary(Hash),
    lists:any(fun({_Number, Value}) -> Value =:= HashBinary end, Slots).

first_free_slot(Number, Capacity, Used) when Number =< Capacity ->
    case lists:member(Number, Used) of
        true -> first_free_slot(Number + 1, Capacity, Used);
        false -> Number
    end.

capacity_slot_number(File, Prefix) ->
    Suffix = ".reserve",
    case lists:prefix(Prefix, File) andalso lists:suffix(Suffix, File) of
        false -> error;
        true ->
            Length = length(File) - length(Prefix) - length(Suffix),
            Digits = lists:sublist(File, length(Prefix) + 1, Length),
            try list_to_integer(Digits) of
                Number when Number > 0 -> {ok, Number};
                _ -> error
            catch _:_ -> error
            end
    end.

is_hash_directory(Parent, File) when length(File) =:= 64 ->
    case file:read_link_info(filename:join(Parent, File)) of
        {ok, #file_info{type = directory}} -> true;
        _ -> false
    end;
is_hash_directory(_Parent, _File) -> false.

capacity_slot_prefix(scope) -> ".adk-scope-slot-";
capacity_slot_prefix(name) -> ".adk-name-slot-".

capacity_reached(scope) -> artifact_scope_capacity_reached;
capacity_reached(name) -> artifact_name_capacity_reached.

capacity_reservation_exhausted(scope) ->
    artifact_scope_capacity_reservation_exhausted;
capacity_reservation_exhausted(name) ->
    artifact_name_capacity_reservation_exhausted.

capacity_reservation_failed(scope) ->
    artifact_scope_capacity_reservation_failed;
capacity_reservation_failed(name) ->
    artifact_name_capacity_reservation_failed.

reserve_version(_NameDir, 0, _MaxScan, _Deadline) ->
    {error, version_reservation_exhausted};
reserve_version(NameDir, Attempts, MaxScan, Deadline) ->
    case request_expired(Deadline) of
        true -> {error, timeout};
        false ->
            case allocated_versions(NameDir, MaxScan) of
                {ok, Versions} ->
                    %% A reserved version can leave at most its reservation,
                    %% payload, and metadata/staging entry behind. Admission
                    %% therefore caps lifetime allocations at one third of
                    %% the bounded directory scan. Reservations are durable
                    %% non-reuse tombstones, so deletion does not restore this
                    %% capacity; callers receive an explicit error before the
                    %% directory becomes unreadable at the scan boundary.
                    Capacity = MaxScan div 3,
                    case length(Versions) >= Capacity of
                        true -> {error, artifact_version_capacity_reached};
                        false ->
                            Version = case Versions of
                                [] -> 1;
                                _ -> lists:max(Versions) + 1
                            end,
                            Reservation = version_path(
                                            NameDir, Version, ".reserve"),
                            case file:write_file(
                                   Reservation, <<>>,
                                   [binary, exclusive, sync]) of
                                ok -> {ok, Version};
                                {error, eexist} ->
                                    reserve_version(
                                      NameDir, Attempts - 1, MaxScan,
                                      Deadline);
                                {error, Reason} ->
                                    {error,
                                     {version_reservation_failed, Reason}}
                            end
                    end;
                {error, _} = Error -> Error
            end
    end.

allocated_versions(NameDir, MaxScan) ->
    case bounded_list_dir(NameDir, MaxScan) of
        {ok, Files} -> {ok, lists:filtermap(fun reservation_version/1, Files)};
        {error, Reason} -> {error, {artifact_directory_unavailable, Reason}}
    end.

persist_artifact(NameDir, Version, Data, Metadata, Deadline) ->
    Token = staging_token(),
    DataPath = version_path(NameDir, Version, ".data"),
    MetaPath = version_path(NameDir, Version, ".meta"),
    DataTemp = DataPath ++ ".tmp-" ++ Token,
    MetaTemp = MetaPath ++ ".tmp-" ++ Token,
    Encoded = term_to_binary(Metadata, [compressed]),
    case file:write_file(DataTemp, Data, [binary, exclusive, sync]) of
        ok ->
            case request_expired(Deadline) of
                true -> cleanup_staging([DataTemp]), {error, timeout};
                false ->
                    persist_data_then_metadata(DataTemp, DataPath, MetaTemp,
                                               MetaPath, Encoded, Deadline)
            end;
        {error, Reason} -> {error, {artifact_data_write_failed, Reason}}
    end.

persist_data_then_metadata(DataTemp, DataPath, MetaTemp, MetaPath, Encoded,
                           Deadline) ->
    case file:rename(DataTemp, DataPath) of
        ok ->
            case file:write_file(MetaTemp, Encoded,
                                 [binary, exclusive, sync]) of
                ok ->
                    case request_expired(Deadline) of
                        true ->
                            cleanup_staging([MetaTemp, DataPath]),
                            {error, timeout};
                        false ->
                            case file:rename(MetaTemp, MetaPath) of
                                ok ->
                                    try binary_to_term(Encoded, [safe]) of
                                        Metadata -> {ok, Metadata}
                                    catch _:_ -> {error, corrupt_artifact}
                                    end;
                                {error, Reason} ->
                                    cleanup_staging([MetaTemp, DataPath]),
                                    {error,
                                     {artifact_publication_failed, Reason}}
                            end
                    end;
                {error, Reason} ->
                    cleanup_staging([DataPath]),
                    {error, {artifact_metadata_write_failed, Reason}}
            end;
        {error, Reason} ->
            cleanup_staging([DataTemp]),
            {error, {artifact_data_publication_failed, Reason}}
    end.

cleanup_staging(Paths) ->
    lists:foreach(fun(Path) -> _ = file:delete(Path) end, Paths), ok.

staging_token() ->
    binary_to_list(binary:encode_hex(
      crypto:hash(sha256, term_to_binary({node(), self(),
                                         erlang:unique_integer([positive,
                                                                monotonic])})),
      lowercase)).

get_artifact(Root, Scope, Name, latest, MaxBytes, MaxScan) ->
    NameDir = name_directory(Root, Scope, Name),
    case committed_versions(NameDir, MaxScan) of
        {ok, []} -> {error, not_found};
        {ok, Versions} ->
            get_artifact(Root, Scope, Name, lists:max(Versions), MaxBytes,
                         MaxScan);
        {error, enoent} -> {error, not_found};
        {error, _} = Error -> Error
    end;
get_artifact(Root, Scope, Name, Version, MaxBytes, _MaxScan) ->
    NameDir = name_directory(Root, Scope, Name),
    case read_metadata(NameDir, Scope, Name, Version) of
        {ok, Metadata} ->
            DataPath = version_path(NameDir, Version, ".data"),
            Expected = maps:get(size, Metadata),
            case Expected =< MaxBytes of
                false -> {error, corrupt_artifact};
                true ->
                    case read_bounded_file(DataPath, Expected) of
                        {ok, Data} ->
                            adk_artifact_core:validate_loaded_data(Metadata,
                                                                   Data);
                        {error, enoent} -> {error, corrupt_artifact};
                        {error, file_too_large} -> {error, corrupt_artifact};
                        {error, Reason} ->
                            {error, {artifact_read_failed, Reason}}
                    end
            end;
        {error, enoent} -> {error, not_found};
        {error, _} = Error -> Error
    end.

committed_versions(NameDir, MaxScan) ->
    case bounded_list_dir(NameDir, MaxScan) of
        {ok, Files} -> {ok, lists:filtermap(fun metadata_version/1, Files)};
        {error, Reason} -> {error, Reason}
    end.

read_metadata(NameDir, Scope, Name, Version) ->
    Path = version_path(NameDir, Version, ".meta"),
    case read_bounded_file(Path, ?MAX_METADATA_FILE_BYTES) of
        {ok, Encoded} ->
            try binary_to_term(Encoded, [safe]) of
                Metadata -> adk_artifact_core:validate_loaded_metadata(
                              Metadata, Scope, Name, Version)
            catch _:_ -> {error, corrupt_artifact}
            end;
        {error, file_too_large} -> {error, corrupt_artifact};
        {error, Reason} -> {error, Reason}
    end.

read_bounded_file(Path, MaxBytes) ->
    case file:read_file_info(Path) of
        {ok, #file_info{type = regular, size = Size}} when Size =< MaxBytes ->
            file:read_file(Path);
        {ok, #file_info{type = regular}} -> {error, file_too_large};
        {ok, _} -> {error, unsafe_file_type};
        {error, Reason} -> {error, Reason}
    end.

legacy_list(Scope, State) ->
    case adk_artifact_core:validate_scope(Scope) of
        ok ->
            case list_scope(State#state.root, Scope,
                            State#state.max_scan_entries) of
                {ok, Items}
                  when length(Items) =< State#state.legacy_list_limit ->
                    {ok, Items};
                {ok, _Items} -> {error, result_limit_exceeded};
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end.

list_names_page(Scope, Options, State) ->
    case {adk_artifact_core:validate_scope(Scope),
          adk_artifact_core:validate_page_options(
            Options, name, State#state.max_page_limit)} of
        {ok, {ok, Limit, Cursor}} ->
            case list_scope(State#state.root, Scope,
                            State#state.max_scan_entries) of
                {ok, Items} ->
                    Names = lists:usort([maps:get(name, Item) || Item <- Items]),
                    {ok, (page_names(Names, Cursor, Limit))#{scope => Scope}};
                {error, _} = Error -> Error
            end;
        {{error, _} = Error, _} -> Error;
        {_, {error, _} = Error} -> Error
    end.

list_versions_page(Scope, Name, Options, State) ->
    case {adk_artifact_core:validate_lookup(Scope, Name, 1),
          adk_artifact_core:validate_page_options(
            Options, version, State#state.max_page_limit)} of
        {ok, {ok, Limit, Cursor}} ->
            NameDir = name_directory(State#state.root, Scope, Name),
            case collect_name_metadata(NameDir, Scope,
                                       State#state.max_scan_entries) of
                {ok, Items} ->
                    Sorted = lists:sort(fun metadata_less_or_equal/2, Items),
                    {ok, page_versions(Sorted, Cursor, Limit)};
                {error, enoent} ->
                    {ok, #{items => [], next_cursor => undefined}};
                {error, _} = Error -> Error
            end;
        {{error, _} = Error, _} -> Error;
        {_, {error, _} = Error} -> Error
    end.

list_scope(Root, Scope, MaxScan) ->
    NamesDir = filename:join(scope_directory(Root, Scope), "names"),
    case bounded_list_dir(NamesDir, MaxScan) of
        {ok, NameDirectories} ->
            collect_scope_metadata(NamesDir, NameDirectories, Scope, [],
                                   MaxScan);
        {error, enoent} -> {ok, []};
        {error, scan_limit_exceeded} -> {error, scan_limit_exceeded};
        {error, Reason} -> {error, {artifact_list_failed, Reason}}
    end.

collect_scope_metadata(_NamesDir, [], _Scope, Acc, _Remaining) ->
    {ok, lists:sort(fun metadata_less_or_equal/2, Acc)};
collect_scope_metadata(_NamesDir, _Directories, _Scope, _Acc, Remaining)
  when Remaining =< 0 ->
    {error, scan_limit_exceeded};
collect_scope_metadata(NamesDir, [Directory | Rest], Scope, Acc, Remaining) ->
    NameDir = filename:join(NamesDir, Directory),
    case file:read_link_info(NameDir) of
        {ok, #file_info{type = directory}} ->
            case collect_name_metadata(NameDir, Scope, Remaining) of
                {ok, Items} when length(Items) =< Remaining ->
                    collect_scope_metadata(NamesDir, Rest, Scope,
                                           Items ++ Acc,
                                           Remaining - length(Items));
                {ok, _} -> {error, scan_limit_exceeded};
                {error, _} = Error -> Error
            end;
        {ok, _Other} ->
            collect_scope_metadata(NamesDir, Rest, Scope, Acc, Remaining);
        {error, enoent} ->
            collect_scope_metadata(NamesDir, Rest, Scope, Acc, Remaining);
        {error, Reason} -> {error, {artifact_list_failed, Reason}}
    end.

collect_name_metadata(NameDir, Scope, MaxScan) ->
    case bounded_list_dir(NameDir, MaxScan) of
        {ok, Files} ->
            Versions = lists:filtermap(fun metadata_version/1, Files),
            collect_versions_metadata(NameDir, Scope, Versions, []);
        {error, Reason} -> {error, Reason}
    end.

collect_versions_metadata(_NameDir, _Scope, [], Acc) -> {ok, Acc};
collect_versions_metadata(NameDir, Scope, [Version | Rest], Acc) ->
    MetaPath = version_path(NameDir, Version, ".meta"),
    case read_bounded_file(MetaPath, ?MAX_METADATA_FILE_BYTES) of
        {ok, Encoded} ->
            try binary_to_term(Encoded, [safe]) of
                #{name := Name} = Metadata ->
                    case adk_artifact_core:validate_loaded_metadata(
                           Metadata, Scope, Name, Version) of
                        {ok, Safe} ->
                            collect_versions_metadata(NameDir, Scope, Rest,
                                                      [Safe | Acc]);
                        {error, _} -> {error, corrupt_artifact}
                    end;
                _ -> {error, corrupt_artifact}
            catch _:_ -> {error, corrupt_artifact}
            end;
        {error, file_too_large} -> {error, corrupt_artifact};
        {error, Reason} -> {error, {artifact_read_failed, Reason}}
    end.

metadata_less_or_equal(Left, Right) ->
    {maps:get(name, Left), maps:get(version, Left)} =<
    {maps:get(name, Right), maps:get(version, Right)}.

delete_artifact(Root, Scope, Name, all, Deadline, MaxScan) ->
    NameDir = name_directory(Root, Scope, Name),
    case committed_versions(NameDir, MaxScan) of
        {ok, []} -> {error, not_found};
        {ok, Versions} -> delete_versions(NameDir, Versions, Deadline);
        {error, enoent} -> {error, not_found};
        {error, Reason} -> {error, {artifact_delete_failed, Reason}}
    end;
delete_artifact(Root, Scope, Name, latest, Deadline, MaxScan) ->
    NameDir = name_directory(Root, Scope, Name),
    case committed_versions(NameDir, MaxScan) of
        {ok, []} -> {error, not_found};
        {ok, Versions} -> delete_versions(NameDir, [lists:max(Versions)],
                                          Deadline);
        {error, enoent} -> {error, not_found};
        {error, Reason} -> {error, {artifact_delete_failed, Reason}}
    end;
delete_artifact(Root, Scope, Name, Version, Deadline, MaxScan) ->
    NameDir = name_directory(Root, Scope, Name),
    case committed_versions(NameDir, MaxScan) of
        {ok, Versions} ->
            case lists:member(Version, Versions) of
                true -> delete_versions(NameDir, [Version], Deadline);
                false -> {error, not_found}
            end;
        {error, enoent} -> {error, not_found};
        {error, Reason} -> {error, {artifact_delete_failed, Reason}}
    end.

delete_versions(_NameDir, [], _Deadline) -> ok;
delete_versions(NameDir, [Version | Rest], Deadline) ->
    case request_expired(Deadline) of
        true -> {error, timeout};
        false ->
            case delete_version(NameDir, Version) of
                ok -> delete_versions(NameDir, Rest, Deadline);
                {error, _} = Error -> Error
            end
    end.

delete_version(NameDir, Version) ->
    MetaPath = version_path(NameDir, Version, ".meta"),
    DataPath = version_path(NameDir, Version, ".data"),
    case file:delete(MetaPath) of
        ok ->
            case file:delete(DataPath) of
                ok -> ok;
                {error, enoent} -> ok;
                {error, Reason} -> {error, {artifact_delete_failed, Reason}}
            end;
        {error, enoent} -> {error, not_found};
        {error, Reason} -> {error, {artifact_delete_failed, Reason}}
    end.

validate_repair_options(Options, State) when is_map(Options) ->
    Unknown = maps:without([limit, min_age_ms], Options),
    Limit = maps:get(limit, Options, State#state.max_scan_entries),
    MinAge = maps:get(min_age_ms, Options, State#state.recovery_grace_ms),
    case {map_size(Unknown),
          is_integer(Limit) andalso Limit > 0 andalso
              Limit =< State#state.max_scan_entries,
          is_integer(MinAge) andalso MinAge >= 0} of
        {Size, _, _} when Size > 0 ->
            {error, {unknown_options, lists:sort(maps:keys(Unknown))}};
        {_, false, _} -> {error, invalid_limit};
        {_, _, false} -> {error, invalid_min_age_ms};
        {0, true, true} -> {ok, Limit, MinAge}
    end;
validate_repair_options(_Options, _State) -> {error, invalid_options}.

repair_root(Root, Limit, MinAgeMs, MaxDirEntries) ->
    Initial = #{scanned => 0, removed => 0, reservations_preserved => 0,
                corrupt => 0},
    ScopesRoot = filename:join(Root, "scopes"),
    case bounded_list_dir(ScopesRoot, MaxDirEntries) of
        {ok, ScopeDirs} ->
            case repair_scope_dirs(ScopesRoot, ScopeDirs, Limit, MinAgeMs,
                                   MaxDirEntries, Initial) of
                {ok, Stats} -> {ok, Stats};
                {error, _} = Error -> Error
            end;
        {error, enoent} -> {ok, Initial};
        {error, Reason} -> {error, {artifact_repair_failed, Reason}}
    end.

repair_scope_dirs(_Root, [], _Limit, _Age, _MaxDir, Stats) -> {ok, Stats};
repair_scope_dirs(Root, [ScopeDir | Rest], Limit, Age, MaxDir, Stats0) ->
    ScopePath = filename:join(Root, ScopeDir),
    case file:read_link_info(ScopePath) of
        {ok, #file_info{type = directory}} ->
            NamesRoot = filename:join(ScopePath, "names"),
            case bounded_list_dir(NamesRoot, MaxDir) of
                {ok, NameDirs} ->
                    case repair_name_dirs(
                           NamesRoot, NameDirs, Limit, Age, MaxDir,
                           Stats0) of
                        {ok, Stats} ->
                            repair_scope_dirs(
                              Root, Rest, Limit, Age, MaxDir, Stats);
                        {error, _} = Error -> Error
                    end;
                {error, enoent} ->
                    repair_scope_dirs(
                      Root, Rest, Limit, Age, MaxDir, Stats0);
                {error, Reason} ->
                    {error, {artifact_repair_failed, Reason}}
            end;
        {ok, _Other} ->
            repair_scope_dirs(Root, Rest, Limit, Age, MaxDir, Stats0);
        {error, enoent} ->
            repair_scope_dirs(Root, Rest, Limit, Age, MaxDir, Stats0);
        {error, Reason} -> {error, {artifact_repair_failed, Reason}}
    end.

repair_name_dirs(_Root, [], _Limit, _Age, _MaxDir, Stats) -> {ok, Stats};
repair_name_dirs(Root, [NameDir | Rest], Limit, Age, MaxDir, Stats0) ->
    Path = filename:join(Root, NameDir),
    case file:read_link_info(Path) of
        {ok, #file_info{type = directory}} ->
            case bounded_list_dir(Path, MaxDir) of
                {ok, Files} ->
                    case repair_files(Path, Files, Limit, Age, Stats0) of
                        {ok, Stats} ->
                            repair_name_dirs(Root, Rest, Limit, Age, MaxDir,
                                             Stats);
                        {error, _} = Error -> Error
                    end;
                {error, Reason} ->
                    {error, {artifact_repair_failed, Reason}}
            end;
        {ok, _} -> repair_name_dirs(Root, Rest, Limit, Age, MaxDir, Stats0);
        {error, enoent} ->
            repair_name_dirs(Root, Rest, Limit, Age, MaxDir, Stats0);
        {error, Reason} -> {error, {artifact_repair_failed, Reason}}
    end.

repair_files(_NameDir, [], _Limit, _Age, Stats) -> {ok, Stats};
repair_files(NameDir, [File | Rest], Limit, Age, Stats0) ->
    Scanned = maps:get(scanned, Stats0),
    case Scanned >= Limit of
        true -> {error, repair_limit_exceeded};
        false ->
            Stats1 = Stats0#{scanned => Scanned + 1},
            case repair_file(NameDir, File, Age, Stats1) of
                {ok, Stats2} -> repair_files(NameDir, Rest, Limit, Age, Stats2);
                {error, _} = Error -> Error
            end
    end.

repair_file(_NameDir, File, _Age, Stats) ->
    case reservation_version(File) of
        {true, _} ->
            {ok, Stats#{reservations_preserved =>
                            maps:get(reservations_preserved, Stats) + 1}};
        false -> repair_non_reservation(_NameDir, File, _Age, Stats)
    end.

repair_non_reservation(NameDir, File, Age, Stats) ->
    Path = filename:join(NameDir, File),
    case is_staging_file(File) of
        true -> maybe_remove_stale(Path, Age, Stats);
        false ->
            case data_version(File) of
                {true, Version} ->
                    case filelib:is_regular(
                           version_path(NameDir, Version, ".meta")) of
                        true -> {ok, Stats};
                        false -> maybe_remove_stale(Path, Age, Stats)
                    end;
                false ->
                    case metadata_version(File) of
                        {true, Version} ->
                            case filelib:is_regular(
                                   version_path(NameDir, Version, ".data")) of
                                true -> {ok, Stats};
                                false ->
                                    {ok, Stats#{corrupt =>
                                                    maps:get(corrupt, Stats) + 1}}
                            end;
                        false -> {ok, Stats}
                    end
            end
    end.

maybe_remove_stale(Path, MinAgeMs, Stats) ->
    case old_enough(Path, MinAgeMs) of
        true ->
            case file:delete(Path) of
                ok -> {ok, Stats#{removed => maps:get(removed, Stats) + 1}};
                {error, enoent} -> {ok, Stats};
                {error, Reason} ->
                    {error, {artifact_repair_failed, Reason}}
            end;
        false -> {ok, Stats};
        {error, Reason} -> {error, {artifact_repair_failed, Reason}}
    end.

old_enough(Path, MinAgeMs) ->
    case file:read_link_info(Path, [{time, posix}]) of
        {ok, #file_info{type = regular, mtime = Mtime}} ->
            AgeMs = erlang:max(0, erlang:system_time(second) - Mtime) * 1000,
            AgeMs >= MinAgeMs;
        {ok, _} -> false;
        {error, Reason} -> {error, Reason}
    end.

is_staging_file(File) -> string:find(File, ".tmp-") =/= nomatch.

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

bounded_list_dir(Path, Limit) ->
    case file:list_dir(Path) of
        {ok, Files} when length(Files) =< Limit -> {ok, Files};
        {ok, _Files} -> {error, scan_limit_exceeded};
        {error, Reason} -> {error, Reason}
    end.

reservation_version(File) -> parse_version_file(File, ".reserve").
metadata_version(File) -> parse_version_file(File, ".meta").
data_version(File) -> parse_version_file(File, ".data").

parse_version_file(File, Suffix) when is_list(File) ->
    Prefix = "v-",
    case lists:prefix(Prefix, File) andalso lists:suffix(Suffix, File) of
        true ->
            DigitsLength = length(File) - length(Prefix) - length(Suffix),
            Digits = lists:sublist(File, length(Prefix) + 1, DigitsLength),
            try list_to_integer(Digits) of
                Version when Version > 0 -> {true, Version};
                _ -> false
            catch _:_ -> false
            end;
        false -> false
    end.

scope_directory(Root, Scope) ->
    filename:join([Root, "scopes", hash_term(Scope)]).

name_directory(Root, Scope, Name) ->
    filename:join([scope_directory(Root, Scope), "names", hash_term(Name)]).

hash_term(Term) ->
    binary_to_list(binary:encode_hex(
                     crypto:hash(sha256, term_to_binary(Term)), lowercase)).

version_path(NameDir, Version, Suffix) ->
    filename:join(NameDir, "v-" ++ integer_to_list(Version) ++ Suffix).

capability_map(State) ->
    #{api_version => 1,
      immutable_versions => true,
      scopes => [app, user, session],
      pagination => #{max_page_limit => State#state.max_page_limit,
                      legacy_list_limit => State#state.legacy_list_limit,
                      max_scan_entries => State#state.max_scan_entries},
      deadlines => true,
      cancellation => deadline,
      persistence => filesystem,
      atomic_publication => metadata_rename,
      recovery => #{mode => explicit,
                    grace_ms => State#state.recovery_grace_ms,
                    reservations_preserved => true},
      quotas => #{max_artifact_bytes => State#state.max_artifact_bytes,
                  max_lifetime_scopes =>
                      State#state.max_scan_entries div 2,
                  max_lifetime_names_per_scope =>
                      State#state.max_scan_entries div 2,
                  max_lifetime_versions_per_name =>
                      State#state.max_scan_entries div 3},
      validation_limits => adk_artifact_core:limits()}.

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
safe_call(_Handle, _Request, _Timeout) -> {error, invalid_handle}.

request_expired(Deadline) -> adk_artifact_core:deadline_expired(Deadline).

valid_utf8(Value) ->
    case unicode:characters_to_binary(Value, utf8, utf8) of
        Value -> true;
        _ -> false
    end.
