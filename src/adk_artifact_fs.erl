%% @doc Durable filesystem artifact service with immutable scoped versions.
%%
%% Logical scope and artifact names are never used as path components.  Their
%% SHA-256 digests select directories and every loaded metadata record is
%% checked against the requested scope/name/version before data is returned.
%% A durable, exclusively-created reservation file allocates each version, so
%% a deleted or interrupted version is never reused, even after restart.
-module(adk_artifact_fs).
-behaviour(adk_artifact_service).
-behaviour(gen_server).

-include_lib("kernel/include/file.hrl").

-export([put/5, get/4, list/2, delete/4, stop/1]).
-export([start_link/1,
         init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

-define(CALL_TIMEOUT, 30000).
-define(DEFAULT_MAX_ARTIFACT_BYTES, 64 * 1024 * 1024).
-define(MAX_RESERVATION_ATTEMPTS, 1024).

-record(state, {
    root :: file:filename_all(),
    max_artifact_bytes :: pos_integer()
}).

-spec start_link(map()) -> {ok, pid()} | {error, term()}.
start_link(Config) when is_map(Config) ->
    case prepare_config(Config) of
        {ok, Root, MaxBytes} ->
            gen_server:start_link(?MODULE, {prepared, Root, MaxBytes}, []);
        {error, _} = Error ->
            Error
    end;
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
             adk_artifact_service:delete_selector()) ->
    ok | {error, term()}.
delete(Handle, Scope, Name, Selector) ->
    safe_call(Handle, {delete, Scope, Name, Selector}).

-spec stop(pid()) -> ok | {error, term()}.
stop(Handle) ->
    safe_call(Handle, stop).

init({prepared, Root, MaxBytes}) ->
    {ok, #state{root = Root, max_artifact_bytes = MaxBytes}};
init(_Config) ->
    {stop, invalid_config}.

prepare_config(Config) ->
    case validate_config(Config) of
        {ok, Root, MaxBytes} ->
            case ensure_private_directory(Root) of
                ok ->
                    StorageRoot = filename:join(Root, "v1"),
                    case ensure_private_directory(StorageRoot) of
                        ok -> {ok, StorageRoot, MaxBytes};
                        {error, _} = Error -> Error
                    end;
                {error, _} = Error ->
                    Error
            end;
        {error, _} = Error ->
            Error
    end.

handle_call({put, Scope, Name, Data, Options}, _From, State) ->
    Reply = case validate_put(Scope, Name, Data, Options,
                              State#state.max_artifact_bytes) of
        {ok, MimeType, UserMetadata} ->
            put_artifact(State#state.root, Scope, Name, Data,
                         MimeType, UserMetadata);
        {error, _} = Error -> Error
    end,
    {reply, Reply, State};
handle_call({get, Scope, Name, Selector}, _From, State) ->
    Reply = case validate_lookup(Scope, Name, Selector) of
        ok -> get_artifact(State#state.root, Scope, Name, Selector);
        {error, _} = Error -> Error
    end,
    {reply, Reply, State};
handle_call({list, Scope}, _From, State) ->
    Reply = case validate_scope(Scope) of
        ok -> list_scope(State#state.root, Scope);
        {error, _} = Error -> Error
    end,
    {reply, Reply, State};
handle_call({delete, Scope, Name, Selector}, _From, State) ->
    Reply = case validate_delete(Scope, Name, Selector) of
        ok -> delete_artifact(State#state.root, Scope, Name, Selector);
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

validate_config(Config) ->
    Unknown = maps:without([root, max_artifact_bytes], Config),
    Root0 = maps:get(root, Config, undefined),
    MaxBytes = maps:get(max_artifact_bytes, Config,
                        ?DEFAULT_MAX_ARTIFACT_BYTES),
    case {map_size(Unknown), normalize_root(Root0),
          is_integer(MaxBytes) andalso MaxBytes > 0} of
        {Size, _, _} when Size > 0 ->
            {error, {unknown_config, lists:sort(maps:keys(Unknown))}};
        {_, {error, _} = Error, _} ->
            Error;
        {_, _, false} ->
            {error, invalid_max_artifact_bytes};
        {0, {ok, Root}, true} ->
            {ok, Root, MaxBytes}
    end.

normalize_root(undefined) ->
    {error, missing_root};
normalize_root(Root) when is_binary(Root), byte_size(Root) > 0 ->
    case valid_utf8(Root) andalso binary:match(Root, <<0>>) =:= nomatch of
        true -> {ok, filename:absname(binary_to_list(Root))};
        false -> {error, invalid_root}
    end;
normalize_root(Root) when is_list(Root), Root =/= [] ->
    try unicode:characters_to_binary(Root) of
        Binary -> normalize_root(Binary)
    catch
        _:_ -> {error, invalid_root}
    end;
normalize_root(_Root) ->
    {error, invalid_root}.

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

put_artifact(Root, Scope, Name, Data, MimeType, UserMetadata) ->
    NameDir = name_directory(Root, Scope, Name),
    case ensure_generated_directories(Root, Scope, NameDir) of
        ok ->
            case reserve_version(NameDir, ?MAX_RESERVATION_ATTEMPTS) of
                {ok, Version} ->
                    Metadata = artifact_metadata(Scope, Name, Version, Data,
                                                 MimeType, UserMetadata),
                    persist_artifact(NameDir, Version, Data, Metadata);
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end.

ensure_generated_directories(Root, Scope, NameDir) ->
    ScopeDir = scope_directory(Root, Scope),
    Paths = [filename:join(Root, "scopes"), ScopeDir,
             filename:join(ScopeDir, "names"), NameDir],
    ensure_directories(Paths).

ensure_directories([]) -> ok;
ensure_directories([Path | Rest]) ->
    case ensure_private_directory(Path) of
        ok -> ensure_directories(Rest);
        {error, _} = Error -> Error
    end.

reserve_version(_NameDir, 0) ->
    {error, version_reservation_exhausted};
reserve_version(NameDir, Attempts) ->
    case allocated_versions(NameDir) of
        {ok, Versions} ->
            Version = case Versions of [] -> 1; _ -> lists:max(Versions) + 1 end,
            Reservation = version_path(NameDir, Version, ".reserve"),
            case file:write_file(Reservation, <<>>,
                                 [binary, exclusive, sync]) of
                ok -> {ok, Version};
                {error, eexist} -> reserve_version(NameDir, Attempts - 1);
                {error, Reason} ->
                    {error, {version_reservation_failed, Reason}}
            end;
        {error, _} = Error -> Error
    end.

allocated_versions(NameDir) ->
    case file:list_dir(NameDir) of
        {ok, Files} ->
            {ok, lists:filtermap(fun reservation_version/1, Files)};
        {error, Reason} ->
            {error, {artifact_directory_unavailable, Reason}}
    end.

reservation_version(File) ->
    parse_version_file(File, ".reserve").

metadata_version(File) ->
    parse_version_file(File, ".meta").

parse_version_file(File, Suffix) when is_list(File) ->
    Prefix = "v-",
    case lists:prefix(Prefix, File) andalso lists:suffix(Suffix, File) of
        true ->
            DigitsLength = length(File) - length(Prefix) - length(Suffix),
            Digits = lists:sublist(File, length(Prefix) + 1, DigitsLength),
            try list_to_integer(Digits) of
                Version when Version > 0 -> {true, Version};
                _ -> false
            catch
                _:_ -> false
            end;
        false -> false
    end.

persist_artifact(NameDir, Version, Data, Metadata) ->
    DataPath = version_path(NameDir, Version, ".data"),
    MetaPath = version_path(NameDir, Version, ".meta"),
    case file:write_file(DataPath, Data, [binary, exclusive, sync]) of
        ok ->
            Encoded = term_to_binary(Metadata, [compressed]),
            case file:write_file(MetaPath, Encoded,
                                 [binary, exclusive, sync]) of
                ok -> {ok, Metadata};
                {error, Reason} ->
                    _ = file:delete(DataPath),
                    {error, {artifact_metadata_write_failed, Reason}}
            end;
        {error, Reason} ->
            {error, {artifact_data_write_failed, Reason}}
    end.

artifact_metadata(Scope, Name, Version, Data, MimeType, UserMetadata) ->
    #{scope => Scope,
      name => Name,
      version => Version,
      mime_type => MimeType,
      digest => digest(Data),
      size => byte_size(Data),
      created_at => erlang:system_time(millisecond),
      metadata => UserMetadata}.

get_artifact(Root, Scope, Name, latest) ->
    NameDir = name_directory(Root, Scope, Name),
    case committed_versions(NameDir) of
        {ok, []} -> {error, not_found};
        {ok, Versions} ->
            get_artifact(Root, Scope, Name, lists:max(Versions));
        {error, enoent} -> {error, not_found};
        {error, _} = Error -> Error
    end;
get_artifact(Root, Scope, Name, Version) ->
    NameDir = name_directory(Root, Scope, Name),
    case read_metadata(NameDir, Scope, Name, Version) of
        {ok, Metadata} ->
            DataPath = version_path(NameDir, Version, ".data"),
            case file:read_file(DataPath) of
                {ok, Data} -> validate_loaded_data(Metadata, Data);
                {error, enoent} -> {error, corrupt_artifact};
                {error, Reason} -> {error, {artifact_read_failed, Reason}}
            end;
        {error, enoent} -> {error, not_found};
        {error, _} = Error -> Error
    end.

committed_versions(NameDir) ->
    case file:list_dir(NameDir) of
        {ok, Files} -> {ok, lists:filtermap(fun metadata_version/1, Files)};
        {error, Reason} -> {error, Reason}
    end.

read_metadata(NameDir, Scope, Name, Version) ->
    Path = version_path(NameDir, Version, ".meta"),
    case file:read_file(Path) of
        {ok, Encoded} ->
            try binary_to_term(Encoded, [safe]) of
                Metadata -> validate_loaded_metadata(
                              Metadata, Scope, Name, Version)
            catch
                _:_ -> {error, corrupt_artifact}
            end;
        {error, Reason} -> {error, Reason}
    end.

validate_loaded_metadata(Metadata, Scope, Name, Version)
  when is_map(Metadata) ->
    Required = [scope, name, version, mime_type, digest, size,
                created_at, metadata],
    case lists:sort(maps:keys(Metadata)) =:= lists:sort(Required) andalso
         maps:get(scope, Metadata, invalid) =:= Scope andalso
         maps:get(name, Metadata, invalid) =:= Name andalso
         maps:get(version, Metadata, invalid) =:= Version andalso
         valid_mime_type(maps:get(mime_type, Metadata, invalid)) andalso
         valid_digest(maps:get(digest, Metadata, invalid)) andalso
         valid_nonnegative_integer(maps:get(size, Metadata, invalid)) andalso
         valid_nonnegative_integer(maps:get(created_at, Metadata, invalid)) andalso
         is_map(maps:get(metadata, Metadata, invalid)) andalso
         json_safe(maps:get(metadata, Metadata, invalid)) of
        true -> {ok, Metadata};
        false -> {error, corrupt_artifact}
    end;
validate_loaded_metadata(_Metadata, _Scope, _Name, _Version) ->
    {error, corrupt_artifact}.

validate_loaded_data(Metadata, Data) ->
    case byte_size(Data) =:= maps:get(size, Metadata) andalso
         digest(Data) =:= maps:get(digest, Metadata) of
        true -> {ok, Metadata#{data => Data}};
        false -> {error, corrupt_artifact}
    end.

list_scope(Root, Scope) ->
    NamesDir = filename:join(scope_directory(Root, Scope), "names"),
    case file:list_dir(NamesDir) of
        {ok, NameDirectories} ->
            collect_scope_metadata(NamesDir, NameDirectories, Scope, []);
        {error, enoent} -> {ok, []};
        {error, Reason} -> {error, {artifact_list_failed, Reason}}
    end.

collect_scope_metadata(_NamesDir, [], _Scope, Acc) ->
    {ok, lists:sort(fun metadata_less_or_equal/2, Acc)};
collect_scope_metadata(NamesDir, [Directory | Rest], Scope, Acc) ->
    NameDir = filename:join(NamesDir, Directory),
    case file:read_link_info(NameDir) of
        {ok, #file_info{type = directory}} ->
            case collect_name_metadata(NameDir, Scope) of
                {ok, Items} ->
                    collect_scope_metadata(NamesDir, Rest, Scope,
                                           Items ++ Acc);
                {error, _} = Error -> Error
            end;
        {ok, _Other} ->
            collect_scope_metadata(NamesDir, Rest, Scope, Acc);
        {error, enoent} ->
            collect_scope_metadata(NamesDir, Rest, Scope, Acc);
        {error, Reason} ->
            {error, {artifact_list_failed, Reason}}
    end.

collect_name_metadata(NameDir, Scope) ->
    case file:list_dir(NameDir) of
        {ok, Files} ->
            Versions = lists:filtermap(fun metadata_version/1, Files),
            collect_versions_metadata(NameDir, Scope, Versions, []);
        {error, Reason} -> {error, {artifact_list_failed, Reason}}
    end.

collect_versions_metadata(_NameDir, _Scope, [], Acc) ->
    {ok, Acc};
collect_versions_metadata(NameDir, Scope, [Version | Rest], Acc) ->
    MetaPath = version_path(NameDir, Version, ".meta"),
    case file:read_file(MetaPath) of
        {ok, Encoded} ->
            try binary_to_term(Encoded, [safe]) of
                #{name := Name} = Metadata ->
                    case validate_loaded_metadata(Metadata, Scope, Name,
                                                  Version) of
                        {ok, Safe} ->
                            collect_versions_metadata(NameDir, Scope, Rest,
                                                      [Safe | Acc]);
                        {error, _} -> {error, corrupt_artifact}
                    end;
                _ -> {error, corrupt_artifact}
            catch
                _:_ -> {error, corrupt_artifact}
            end;
        {error, Reason} -> {error, {artifact_read_failed, Reason}}
    end.

metadata_less_or_equal(Left, Right) ->
    {maps:get(name, Left), maps:get(version, Left)} =<
    {maps:get(name, Right), maps:get(version, Right)}.

delete_artifact(Root, Scope, Name, all) ->
    NameDir = name_directory(Root, Scope, Name),
    case committed_versions(NameDir) of
        {ok, []} -> {error, not_found};
        {ok, Versions} -> delete_versions(NameDir, Versions);
        {error, enoent} -> {error, not_found};
        {error, Reason} -> {error, {artifact_delete_failed, Reason}}
    end;
delete_artifact(Root, Scope, Name, latest) ->
    NameDir = name_directory(Root, Scope, Name),
    case committed_versions(NameDir) of
        {ok, []} -> {error, not_found};
        {ok, Versions} -> delete_versions(NameDir, [lists:max(Versions)]);
        {error, enoent} -> {error, not_found};
        {error, Reason} -> {error, {artifact_delete_failed, Reason}}
    end;
delete_artifact(Root, Scope, Name, Version) ->
    NameDir = name_directory(Root, Scope, Name),
    case lists:member(Version,
                      case committed_versions(NameDir) of
                          {ok, Versions} -> Versions;
                          _ -> []
                      end) of
        true -> delete_versions(NameDir, [Version]);
        false -> {error, not_found}
    end.

delete_versions(NameDir, Versions) ->
    case lists:foldl(
           fun(Version, ok) -> delete_version(NameDir, Version);
              (_Version, {error, _} = Error) -> Error
           end, ok, Versions) of
        ok -> ok;
        {error, _} = Error -> Error
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

scope_directory(Root, Scope) ->
    filename:join([Root, "scopes", hash_term(Scope)]).

name_directory(Root, Scope, Name) ->
    filename:join([scope_directory(Root, Scope), "names", hash_term(Name)]).

hash_term(Term) ->
    binary_to_list(binary:encode_hex(
                     crypto:hash(sha256, term_to_binary(Term)), lowercase)).

version_path(NameDir, Version, Suffix) ->
    filename:join(NameDir, "v-" ++ integer_to_list(Version) ++ Suffix).

validate_put(Scope, Name, Data, Options, MaxBytes)
  when is_binary(Data), is_map(Options) ->
    case byte_size(Data) =< MaxBytes of
        false -> {error, artifact_too_large};
        true ->
            case {validate_scope(Scope), validate_name(Name),
                  validate_options(Options)} of
                {ok, ok, {ok, MimeType, Metadata}} ->
                    {ok, MimeType, Metadata};
                {{error, _} = Error, _, _} -> Error;
                {_, {error, _} = Error, _} -> Error;
                {_, _, {error, _} = Error} -> Error
            end
    end;
validate_put(_Scope, _Name, Data, _Options, _MaxBytes)
  when not is_binary(Data) ->
    {error, invalid_data};
validate_put(_Scope, _Name, _Data, _Options, _MaxBytes) ->
    {error, invalid_options}.

validate_lookup(Scope, Name, Selector) ->
    case {validate_scope(Scope), validate_name(Name), valid_selector(Selector)} of
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
    MimeType = maps:get(mime_type, Options, <<"application/octet-stream">>),
    Metadata = maps:get(metadata, Options, #{}),
    case {map_size(Unknown), valid_mime_type(MimeType), json_safe(Metadata)} of
        {0, true, true} when is_map(Metadata) -> {ok, MimeType, Metadata};
        {Size, _, _} when Size > 0 ->
            {error, {unknown_options, lists:sort(maps:keys(Unknown))}};
        {_, false, _} -> {error, invalid_mime_type};
        _ -> {error, invalid_metadata}
    end.

valid_mime_type(MimeType) when is_binary(MimeType), byte_size(MimeType) > 2 ->
    valid_utf8(MimeType) andalso
    binary:match(MimeType, <<"/">>) =/= nomatch andalso
    binary:match(MimeType, <<"\r">>) =:= nomatch andalso
    binary:match(MimeType, <<"\n">>) =:= nomatch andalso
    binary:match(MimeType, <<0>>) =:= nomatch;
valid_mime_type(_) -> false.

valid_digest(Digest) when is_binary(Digest), byte_size(Digest) =:= 64 ->
    lists:all(fun(C) -> (C >= $0 andalso C =< $9) orelse
                        (C >= $a andalso C =< $f)
              end, binary_to_list(Digest));
valid_digest(_) -> false.

valid_nonnegative_integer(Value) ->
    is_integer(Value) andalso Value >= 0.

valid_selector(latest) -> true;
valid_selector(Version) -> is_integer(Version) andalso Version > 0.

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
    lists:all(fun({Key, Item}) ->
                      is_binary(Key) andalso valid_utf8(Key) andalso
                      json_safe(Item)
              end, maps:to_list(Value));
json_safe(_) -> false.
