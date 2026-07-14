%% @doc Shared validation and bounded-call helpers for artifact adapters.
-module(adk_artifact_core).

-export([
    limits/0,
    validate_scope/1,
    validate_name/1,
    validate_put/4,
    validate_lookup/3,
    validate_delete/3,
    validate_page_options/3,
    validate_call_options/2,
    deadline_expired/1,
    artifact_metadata/6,
    validate_loaded_metadata/4,
    validate_loaded_data/2,
    digest/1
]).

-define(MAX_SCOPE_PART_BYTES, 256).
-define(MAX_NAME_BYTES, 1024).
-define(MAX_MIME_TYPE_BYTES, 255).
-define(MAX_METADATA_BYTES, 16384).
-define(MAX_METADATA_ENTRIES, 128).
-define(MAX_METADATA_DEPTH, 8).
-define(MAX_CALL_TIMEOUT_MS, 300000).

-spec limits() -> map().
limits() ->
    #{max_scope_part_bytes => ?MAX_SCOPE_PART_BYTES,
      max_name_bytes => ?MAX_NAME_BYTES,
      max_mime_type_bytes => ?MAX_MIME_TYPE_BYTES,
      max_metadata_bytes => ?MAX_METADATA_BYTES,
      max_metadata_entries => ?MAX_METADATA_ENTRIES,
      max_metadata_depth => ?MAX_METADATA_DEPTH,
      max_call_timeout_ms => ?MAX_CALL_TIMEOUT_MS}.

-spec validate_scope(term()) -> ok | {error, term()}.
validate_scope({app, AppName}) ->
    validate_scope_part(app_name, AppName);
validate_scope({user, AppName, UserId}) ->
    validate_scope_parts([{app_name, AppName}, {user_id, UserId}]);
validate_scope({session, AppName, UserId, SessionId}) ->
    validate_scope_parts([{app_name, AppName}, {user_id, UserId},
                          {session_id, SessionId}]);
validate_scope(_Scope) ->
    {error, invalid_scope}.

-spec validate_name(term()) -> ok | {error, term()}.
validate_name(Name)
  when is_binary(Name), byte_size(Name) > 0,
       byte_size(Name) =< ?MAX_NAME_BYTES ->
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

-spec validate_put(term(), term(), term(), term()) ->
    {ok, binary(), map()} | {error, term()}.
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

-spec validate_lookup(term(), term(), term()) -> ok | {error, term()}.
validate_lookup(Scope, Name, Selector) ->
    case {validate_scope(Scope), validate_name(Name),
          valid_selector(Selector)} of
        {ok, ok, true} -> ok;
        {{error, _} = Error, _, _} -> Error;
        {_, {error, _} = Error, _} -> Error;
        {_, _, false} -> {error, invalid_selector}
    end.

-spec validate_delete(term(), term(), term()) -> ok | {error, term()}.
validate_delete(Scope, Name, all) ->
    case {validate_scope(Scope), validate_name(Name)} of
        {ok, ok} -> ok;
        {{error, _} = Error, _} -> Error;
        {_, {error, _} = Error} -> Error
    end;
validate_delete(Scope, Name, Selector) ->
    validate_lookup(Scope, Name, Selector).

-spec validate_page_options(term(), name | version, pos_integer()) ->
    {ok, pos_integer(), undefined | binary() | pos_integer()} |
    {error, term()}.
validate_page_options(Options, CursorType, MaxLimit) when is_map(Options) ->
    Unknown = maps:without([limit, cursor], Options),
    Limit = maps:get(limit, Options, erlang:min(100, MaxLimit)),
    Cursor = maps:get(cursor, Options, undefined),
    case {map_size(Unknown), valid_limit(Limit, MaxLimit),
          valid_cursor(CursorType, Cursor)} of
        {Size, _, _} when Size > 0 ->
            {error, {unknown_options, lists:sort(maps:keys(Unknown))}};
        {_, false, _} -> {error, invalid_limit};
        {_, _, false} -> {error, invalid_cursor};
        {0, true, true} -> {ok, Limit, Cursor}
    end;
validate_page_options(_Options, _CursorType, _MaxLimit) ->
    {error, invalid_options}.

-spec validate_call_options(term(), pos_integer()) ->
    {ok, pos_integer(), integer()} | {error, term()}.
validate_call_options(Options, DefaultTimeout) when is_map(Options) ->
    Unknown = maps:without([timeout_ms], Options),
    Timeout = maps:get(timeout_ms, Options, DefaultTimeout),
    case {map_size(Unknown), is_integer(Timeout) andalso Timeout > 0 andalso
                             Timeout =< ?MAX_CALL_TIMEOUT_MS} of
        {Size, _} when Size > 0 ->
            {error, {unknown_call_options,
                     lists:sort(maps:keys(Unknown))}};
        {_, false} -> {error, invalid_timeout_ms};
        {0, true} ->
            {ok, Timeout, erlang:monotonic_time(millisecond) + Timeout}
    end;
validate_call_options(_Options, _DefaultTimeout) ->
    {error, invalid_call_options}.

-spec deadline_expired(integer()) -> boolean().
deadline_expired(Deadline) ->
    erlang:monotonic_time(millisecond) >= Deadline.

-spec artifact_metadata(adk_artifact_service:scope(), binary(),
                        pos_integer(), binary(), binary(), map()) -> map().
artifact_metadata(Scope, Name, Version, Data, MimeType, UserMetadata) ->
    #{scope => Scope,
      name => Name,
      version => Version,
      mime_type => MimeType,
      digest => digest(Data),
      size => byte_size(Data),
      created_at => erlang:system_time(millisecond),
      metadata => UserMetadata}.

-spec validate_loaded_metadata(term(), adk_artifact_service:scope(),
                               binary(), pos_integer()) ->
    {ok, adk_artifact_service:artifact_meta()} | {error, corrupt_artifact}.
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
         valid_metadata(maps:get(metadata, Metadata, invalid)) of
        true -> {ok, Metadata};
        false -> {error, corrupt_artifact}
    end;
validate_loaded_metadata(_Metadata, _Scope, _Name, _Version) ->
    {error, corrupt_artifact}.

-spec validate_loaded_data(map(), binary()) ->
    {ok, map()} | {error, corrupt_artifact}.
validate_loaded_data(Metadata, Data) ->
    case byte_size(Data) =:= maps:get(size, Metadata) andalso
         digest(Data) =:= maps:get(digest, Metadata) of
        true -> {ok, Metadata#{data => Data}};
        false -> {error, corrupt_artifact}
    end.

-spec digest(binary()) -> binary().
digest(Data) ->
    binary:encode_hex(crypto:hash(sha256, Data), lowercase).

validate_scope_parts([]) -> ok;
validate_scope_parts([{Label, Value} | Rest]) ->
    case validate_scope_part(Label, Value) of
        ok -> validate_scope_parts(Rest);
        {error, _} = Error -> Error
    end.

validate_scope_part(Label, Value)
  when is_binary(Value), byte_size(Value) > 0,
       byte_size(Value) =< ?MAX_SCOPE_PART_BYTES ->
    case valid_utf8(Value) andalso binary:match(Value, <<0>>) =:= nomatch of
        true -> ok;
        false -> {error, {invalid_scope_part, Label}}
    end;
validate_scope_part(Label, _Value) ->
    {error, {invalid_scope_part, Label}}.

validate_options(Options) ->
    Unknown = maps:without([mime_type, metadata], Options),
    MimeType = maps:get(mime_type, Options,
                        <<"application/octet-stream">>),
    Metadata = maps:get(metadata, Options, #{}),
    case {map_size(Unknown), valid_mime_type(MimeType),
          valid_metadata(Metadata)} of
        {Size, _, _} when Size > 0 ->
            {error, {unknown_options, lists:sort(maps:keys(Unknown))}};
        {_, false, _} -> {error, invalid_mime_type};
        {_, _, false} -> {error, invalid_metadata};
        {0, true, true} -> {ok, MimeType, Metadata}
    end.

valid_mime_type(MimeType)
  when is_binary(MimeType), byte_size(MimeType) > 2,
       byte_size(MimeType) =< ?MAX_MIME_TYPE_BYTES ->
    valid_utf8(MimeType) andalso
    binary:match(MimeType, <<"/">>) =/= nomatch andalso
    binary:match(MimeType, <<"\r">>) =:= nomatch andalso
    binary:match(MimeType, <<"\n">>) =:= nomatch andalso
    binary:match(MimeType, <<0>>) =:= nomatch;
valid_mime_type(_) -> false.

valid_metadata(Metadata) when is_map(Metadata) ->
    case metadata_shape(Metadata, 1) of
        {ok, Entries} when Entries =< ?MAX_METADATA_ENTRIES ->
            byte_size(term_to_binary(Metadata)) =< ?MAX_METADATA_BYTES;
        _ -> false
    end;
valid_metadata(_) -> false.

metadata_shape(_Value, Depth) when Depth > ?MAX_METADATA_DEPTH -> error;
metadata_shape(Value, _Depth) when is_binary(Value) ->
    case valid_utf8(Value) of true -> {ok, 0}; false -> error end;
metadata_shape(Value, _Depth) when is_integer(Value); is_float(Value) ->
    {ok, 0};
metadata_shape(true, _Depth) -> {ok, 0};
metadata_shape(false, _Depth) -> {ok, 0};
metadata_shape(null, _Depth) -> {ok, 0};
metadata_shape(Value, Depth) when is_list(Value) ->
    metadata_items(Value, Depth + 1, length(Value));
metadata_shape(Value, Depth) when is_map(Value) ->
    Pairs = maps:to_list(Value),
    case lists:all(fun({Key, _}) -> is_binary(Key) andalso valid_utf8(Key)
                   end, Pairs) of
        true -> metadata_map_items(Pairs, Depth + 1, length(Pairs));
        false -> error
    end;
metadata_shape(_Value, _Depth) -> error.

metadata_items([], _Depth, Count) -> {ok, Count};
metadata_items([Item | Rest], Depth, Count0) ->
    case metadata_shape(Item, Depth) of
        {ok, Count} when Count0 + Count =< ?MAX_METADATA_ENTRIES ->
            metadata_items(Rest, Depth, Count0 + Count);
        _ -> error
    end.

metadata_map_items([], _Depth, Count) -> {ok, Count};
metadata_map_items([{_Key, Item} | Rest], Depth, Count0) ->
    case metadata_shape(Item, Depth) of
        {ok, Count} when Count0 + Count =< ?MAX_METADATA_ENTRIES ->
            metadata_map_items(Rest, Depth, Count0 + Count);
        _ -> error
    end.

valid_utf8(Value) ->
    case unicode:characters_to_binary(Value, utf8, utf8) of
        Value -> true;
        _ -> false
    end.

valid_selector(latest) -> true;
valid_selector(Version) -> is_integer(Version) andalso Version > 0.

valid_limit(Limit, MaxLimit) ->
    is_integer(Limit) andalso Limit > 0 andalso Limit =< MaxLimit.

valid_cursor(name, undefined) -> true;
valid_cursor(name, Cursor) when is_binary(Cursor) ->
    validate_name(Cursor) =:= ok;
valid_cursor(version, undefined) -> true;
valid_cursor(version, Cursor) -> is_integer(Cursor) andalso Cursor > 0;
valid_cursor(_Type, _Cursor) -> false.

valid_digest(Digest) when is_binary(Digest), byte_size(Digest) =:= 64 ->
    lists:all(fun(C) -> (C >= $0 andalso C =< $9) orelse
                        (C >= $a andalso C =< $f)
              end, binary_to_list(Digest));
valid_digest(_) -> false.

valid_nonnegative_integer(Value) ->
    is_integer(Value) andalso Value >= 0.
