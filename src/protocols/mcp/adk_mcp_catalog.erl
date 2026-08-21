%% @doc Immutable, generation-based MCP tools/resources/prompts catalog.
%%
%% A replacement validates and constructs all three registries before returning
%% a new catalog.  Existing snapshots remain immutable, so concurrent users can
%% observe either the complete old generation or the complete new generation,
%% never a mixed set.  Entries are public JSON descriptors; executable handlers
%% and credentials belong outside this catalog.
-module(adk_mcp_catalog).

-export([new/0, new/1, replace/2, snapshot/1, generation/1,
         list/4, lookup/3, list_changed/2, describe/1, kinds/0]).

-define(CATALOG_TAG, adk_mcp_catalog).
-define(SNAPSHOT_TAG, adk_mcp_catalog_snapshot).
-define(VERSION, 1).
-define(MAX_ENTRIES_PER_KIND, 1024).
-define(MAX_CATALOG_BYTES, 16777216).
-define(MAX_PAGE_SIZE, 256).
-define(MAX_CURSOR_BYTES, 2048).
-define(SEAL_KEY, {?MODULE, snapshot_seal_key}).

-type kind() :: tools | resources | prompts.
-type catalog() ::
    {?CATALOG_TAG, ?VERSION, pos_integer(), binary(), binary(), binary(),
     snapshot()}.
-opaque snapshot() ::
    {?SNAPSHOT_TAG, ?VERSION, pos_integer(), binary(), binary(), binary(),
     #{kind() => map()}}.

-export_type([kind/0, catalog/0, snapshot/0]).

-spec new() -> {ok, catalog()}.
new() -> new(#{}).

-spec new(map()) -> {ok, catalog()} | {error, term()}.
new(Definitions) ->
    build_catalog(1, new_instance, Definitions).

-spec replace(catalog() | snapshot(), map()) ->
    {ok, catalog()} | {error, term()}.
replace(Catalog, Definitions) ->
    case snapshot(Catalog) of
        {ok, {?SNAPSHOT_TAG, ?VERSION, Generation, InstanceId,
              _RevisionId, _Seal, _Entries}} ->
            build_catalog(Generation + 1, InstanceId, Definitions);
        {error, _} -> {error, invalid_mcp_catalog}
    end.

-spec snapshot(catalog() | snapshot()) ->
    {ok, snapshot()} | {error, invalid_mcp_catalog}.
snapshot({?CATALOG_TAG, ?VERSION, Generation, InstanceId, RevisionId, Seal,
          {?SNAPSHOT_TAG, ?VERSION, Generation, InstanceId, RevisionId,
           Seal, _Entries} = Snapshot}) ->
    snapshot(Snapshot);
snapshot({?SNAPSHOT_TAG, ?VERSION, Generation, InstanceId, RevisionId,
          Seal, Entries} = Snapshot)
  when is_integer(Generation), Generation > 0, is_map(Entries) ->
    case valid_token(InstanceId) andalso valid_token(RevisionId) andalso
         is_binary(Seal) andalso byte_size(Seal) =:= 32 andalso
         seal_matches(Seal, Generation, InstanceId, RevisionId, Entries)
         andalso valid_entries_shape(Entries) of
        true -> {ok, Snapshot};
        false -> {error, invalid_mcp_catalog}
    end;
snapshot(_Catalog) -> {error, invalid_mcp_catalog}.

-spec generation(catalog() | snapshot()) ->
    {ok, pos_integer()} | {error, invalid_mcp_catalog}.
generation(Catalog) ->
    case snapshot(Catalog) of
        {ok, {?SNAPSHOT_TAG, ?VERSION, Generation, _InstanceId,
              _RevisionId, _Seal, _Entries}} -> {ok, Generation};
        {error, _} = Error -> Error
    end.

%% @doc Return one deterministic page.  Cursors are opaque, authenticated, and
%% bound to the exact catalog generation and kind.
-spec list(catalog() | snapshot(), kind(), undefined | binary(),
           pos_integer()) -> {ok, map()} | {error, term()}.
list(Catalog, Kind, Cursor, Limit)
  when is_integer(Limit), Limit > 0, Limit =< ?MAX_PAGE_SIZE ->
    case {snapshot(Catalog), valid_kind(Kind)} of
        {{ok, {?SNAPSHOT_TAG, ?VERSION, Generation, InstanceId,
               RevisionId, _Seal, Entries}}, true} ->
            case cursor_offset(Cursor, InstanceId, RevisionId, Generation,
                               Kind) of
                {ok, Offset} ->
                    Sorted = sorted_entries(maps:get(Kind, Entries)),
                    page(Sorted, Offset, Limit, InstanceId, RevisionId,
                         Generation, Kind);
                {error, _} = Error -> Error
            end;
        {{error, _} = Error, _} -> Error;
        {_, false} -> {error, invalid_mcp_catalog_kind}
    end;
list(_Catalog, _Kind, _Cursor, _Limit) ->
    {error, invalid_mcp_catalog_page}.

-spec lookup(catalog() | snapshot(), kind(), binary()) ->
    {ok, map()} | {error, term()}.
lookup(Catalog, Kind, Id) ->
    case {snapshot(Catalog), valid_kind(Kind), valid_entry_id(Kind, Id)} of
        {{ok, {?SNAPSHOT_TAG, ?VERSION, _Generation, _InstanceId,
               _RevisionId, _Seal, Entries}}, true, true} ->
            case maps:find(Id, maps:get(Kind, Entries)) of
                {ok, Descriptor} -> {ok, Descriptor};
                error -> {error, mcp_catalog_entry_not_found}
            end;
        {{error, _} = Error, _, _} -> Error;
        {_, false, _} -> {error, invalid_mcp_catalog_kind};
        {_, _, false} -> {error, invalid_mcp_catalog_id}
    end.

-spec list_changed(catalog() | snapshot(), catalog() | snapshot()) ->
    {ok, map()} | {error, term()}.
list_changed(OldCatalog, NewCatalog) ->
    case {snapshot(OldCatalog), snapshot(NewCatalog)} of
        {{ok, {?SNAPSHOT_TAG, ?VERSION, OldGeneration, OldInstance,
               _OldRevision, _OldSeal, OldEntries}},
         {ok, {?SNAPSHOT_TAG, ?VERSION, NewGeneration, NewInstance,
               _NewRevision, _NewSeal, NewEntries}}} ->
            case OldInstance =:= NewInstance andalso
                 NewGeneration > OldGeneration of
                true ->
                    Changed = maps:from_list(
                                [{Kind,
                                  maps:get(Kind, OldEntries) =/=
                                      maps:get(Kind, NewEntries)}
                                 || Kind <- kinds()]),
                    Notifications =
                        [notification_method(Kind)
                         || Kind <- kinds(), maps:get(Kind, Changed)],
                    {ok, #{from_generation => OldGeneration,
                           to_generation => NewGeneration,
                           changed => Changed,
                           notifications => Notifications}};
                false -> {error, unrelated_mcp_catalog_generations}
            end;
        {{error, _} = Error, _} -> Error;
        {_, {error, _} = Error} -> Error
    end.

%% @doc Content-free metadata suitable for logs and process diagnostics.
-spec describe(catalog() | snapshot()) -> {ok, map()} | {error, term()}.
describe(Catalog) ->
    case snapshot(Catalog) of
        {ok, {?SNAPSHOT_TAG, ?VERSION, Generation, InstanceId,
              RevisionId, _Seal, Entries}} ->
            Counts = maps:from_list(
                       [{Kind, map_size(maps:get(Kind, Entries))}
                        || Kind <- kinds()]),
            {ok, #{version => ?VERSION, generation => Generation,
                   instance_id => InstanceId,
                   revision_id => RevisionId, counts => Counts}};
        {error, _} = Error -> Error
    end.

-spec kinds() -> [kind()].
kinds() -> [tools, resources, prompts].

build_catalog(Generation, Instance0, Definitions) when is_map(Definitions) ->
    case maps:keys(maps:without(kinds(), Definitions)) of
        [] ->
            case compile_kinds(kinds(), Definitions, #{}) of
                {ok, Entries} ->
                    case catalog_size(Entries) of
                        ok ->
                            InstanceId = catalog_instance_id(Instance0),
                            RevisionId = random_id(),
                            Seal = seal(Generation, InstanceId, RevisionId,
                                        Entries),
                            Snapshot = {?SNAPSHOT_TAG, ?VERSION, Generation,
                                        InstanceId, RevisionId, Seal, Entries},
                            {ok, {?CATALOG_TAG, ?VERSION, Generation,
                                  InstanceId, RevisionId, Seal, Snapshot}};
                        {error, _} = Error -> Error
                    end;
                {error, _} = Error -> Error
            end;
        _Unknown -> {error, unknown_mcp_catalog_keys}
    end;
build_catalog(_Generation, _Instance, _Definitions) ->
    {error, invalid_mcp_catalog_definitions}.

compile_kinds([], _Definitions, Acc) -> {ok, Acc};
compile_kinds([Kind | Rest], Definitions, Acc) ->
    case compile_entries(Kind, maps:get(Kind, Definitions, [])) of
        {ok, Entries} ->
            compile_kinds(Rest, Definitions, Acc#{Kind => Entries});
        {error, _} = Error -> Error
    end.

compile_entries(Kind, Values) when is_list(Values) ->
    case bounded_list(Values, ?MAX_ENTRIES_PER_KIND) of
        true -> compile_entry_list(Kind, Values, #{});
        false -> {error, {mcp_catalog_capacity_exceeded, Kind}}
    end;
compile_entries(Kind, _Values) ->
    {error, {invalid_mcp_catalog_entries, Kind}}.

compile_entry_list(_Kind, [], Acc) -> {ok, Acc};
compile_entry_list(Kind, [Descriptor0 | Rest], Acc)
  when is_map(Descriptor0) ->
    case validate_descriptor(Kind, Descriptor0) of
        {ok, Id, Descriptor} ->
            case maps:is_key(Id, Acc) of
                true -> {error, {duplicate_mcp_catalog_entry, Kind}};
                false ->
                    compile_entry_list(Kind, Rest,
                                       Acc#{Id => Descriptor})
            end;
        {error, _} = Error -> Error
    end;
compile_entry_list(Kind, [_Invalid | _Rest], _Acc) ->
    {error, {invalid_mcp_catalog_entry, Kind}};
compile_entry_list(Kind, _Improper, _Acc) ->
    {error, {invalid_mcp_catalog_entries, Kind}}.

validate_descriptor(Kind, Descriptor0) ->
    case adk_mcp_protocol_limits:validate_json(
           Descriptor0,
           #{max_bytes => 262144, max_depth => 32,
             max_nodes => 10000, max_binary_bytes => 131072,
             max_total_binary_bytes => 262144,
             max_list_length => 2048, max_map_size => 1024,
             max_external_bytes => 1048576}) of
        {ok, Descriptor} ->
            Key = entry_key(Kind),
            case maps:get(Key, Descriptor, undefined) of
                Id when is_binary(Id) ->
                    case valid_entry_id(Kind, Id) of
                        true -> {ok, Id, Descriptor};
                        false -> {error, {invalid_mcp_catalog_id, Kind}}
                    end;
                _ -> {error, {missing_mcp_catalog_id, Kind}}
            end;
        {error, _} = Error -> Error
    end.

valid_entries_shape(Entries) ->
    lists:sort(maps:keys(Entries)) =:= lists:sort(kinds()) andalso
        catalog_size(Entries) =:= ok andalso
        lists:all(
          fun(Kind) ->
              Values = maps:get(Kind, Entries),
              is_map(Values) andalso
                  map_size(Values) =< ?MAX_ENTRIES_PER_KIND
          end, kinds()).

catalog_size(Entries) ->
    try erlang:external_size(Entries) of
        Bytes when Bytes =< ?MAX_CATALOG_BYTES -> ok;
        _Bytes -> {error, mcp_catalog_too_large}
    catch
        _:_ -> {error, invalid_mcp_catalog}
    end.

sorted_entries(Entries) ->
    [Descriptor || {_Id, Descriptor} <- lists:sort(maps:to_list(Entries))].

page(Sorted, Offset, Limit, InstanceId, RevisionId, Generation, Kind) ->
    case Offset =< length(Sorted) of
        false -> {error, invalid_mcp_catalog_cursor};
        true ->
            Tail = drop(Sorted, Offset),
            {Items, Rest} = take(Tail, Limit, []),
            NextOffset = Offset + length(Items),
            NextCursor = case Rest of
                [] -> undefined;
                _ -> encode_cursor(InstanceId, RevisionId, Generation,
                                   Kind, NextOffset)
            end,
            Base = #{kind => Kind, generation => Generation,
                     items => Items},
            {ok, maybe_put(next_cursor, NextCursor, Base)}
    end.

cursor_offset(undefined, _InstanceId, _RevisionId, _Generation, _Kind) ->
    {ok, 0};
cursor_offset(Cursor, InstanceId, RevisionId, Generation, Kind)
  when is_binary(Cursor), byte_size(Cursor) =< ?MAX_CURSOR_BYTES ->
    case decode_cursor(Cursor) of
        {ok, InstanceId, RevisionId, Generation, Kind, Offset}
          when is_integer(Offset), Offset >= 0 -> {ok, Offset};
        {ok, _OtherInstance, _OtherRevision, _OtherGeneration,
         _OtherKind, _Offset} -> {error, stale_mcp_catalog_cursor};
        error -> {error, invalid_mcp_catalog_cursor}
    end;
cursor_offset(_Cursor, _InstanceId, _RevisionId, _Generation, _Kind) ->
    {error, invalid_mcp_catalog_cursor}.

encode_cursor(InstanceId, RevisionId, Generation, Kind, Offset) ->
    Payload = term_to_binary(
                {?VERSION, InstanceId, RevisionId, Generation, Kind, Offset},
                [deterministic]),
    Mac = crypto:mac(hmac, sha256, snapshot_seal_key(), Payload),
    base64url(<<Mac/binary, Payload/binary>>).

decode_cursor(Cursor) ->
    try base64url_decode(Cursor) of
        <<Mac:32/binary, Payload/binary>> ->
            Expected = crypto:mac(hmac, sha256, snapshot_seal_key(), Payload),
            case secure_equal(Mac, Expected) of
                true ->
                    case binary_to_term(Payload, [safe]) of
                        {?VERSION, InstanceId, RevisionId, Generation,
                         Kind, Offset} ->
                            {ok, InstanceId, RevisionId, Generation,
                             Kind, Offset};
                        _ -> error
                    end;
                false -> error
            end;
        _ -> error
    catch
        _:_ -> error
    end.

seal_matches(Seal, Generation, InstanceId, RevisionId, Entries) ->
    secure_equal(Seal, seal(Generation, InstanceId, RevisionId, Entries)).

seal(Generation, InstanceId, RevisionId, Entries) ->
    crypto:mac(hmac, sha256, snapshot_seal_key(),
               term_to_binary(
                 {Generation, InstanceId, RevisionId, Entries},
                 [deterministic])).

snapshot_seal_key() ->
    case persistent_term:get(?SEAL_KEY, undefined) of
        Key when is_binary(Key), byte_size(Key) =:= 32 -> Key;
        undefined -> initialize_snapshot_seal_key()
    end.

initialize_snapshot_seal_key() ->
    Lock = {{?MODULE, snapshot_seal_key, node()}, self()},
    global:trans(
      Lock,
      fun() ->
          case persistent_term:get(?SEAL_KEY, undefined) of
              Key when is_binary(Key), byte_size(Key) =:= 32 -> Key;
              undefined ->
                  Key = crypto:strong_rand_bytes(32),
                  persistent_term:put(?SEAL_KEY, Key),
                  Key
          end
      end, [node()]).

catalog_instance_id(new_instance) -> random_id();
catalog_instance_id(InstanceId) -> InstanceId.

random_id() ->
    binary:encode_hex(crypto:strong_rand_bytes(32), lowercase).

valid_token(Token) when is_binary(Token), byte_size(Token) =:= 64 ->
    lists:all(
      fun(C) -> (C >= $0 andalso C =< $9) orelse
                (C >= $a andalso C =< $f)
      end, binary_to_list(Token));
valid_token(_Token) -> false.

secure_equal(Left, Right) when byte_size(Left) =:= byte_size(Right) ->
    try crypto:hash_equals(Left, Right)
    catch
        _:_ -> false
    end;
secure_equal(_Left, _Right) -> false.

entry_key(tools) -> <<"name">>;
entry_key(resources) -> <<"uri">>;
entry_key(prompts) -> <<"name">>.

valid_entry_id(resources, Id) -> valid_text(Id, 2048);
valid_entry_id(Kind, Id) when Kind =:= tools; Kind =:= prompts ->
    valid_text(Id, 256);
valid_entry_id(_Kind, _Id) -> false.

valid_text(Value, Max) when is_binary(Value) ->
    byte_size(Value) > 0 andalso byte_size(Value) =< Max andalso
        valid_utf8(Value);
valid_text(_Value, _Max) -> false.

valid_utf8(Value) ->
    try unicode:characters_to_binary(Value, utf8, utf8) of
        Value -> true;
        _ -> false
    catch
        _:_ -> false
    end.

valid_kind(tools) -> true;
valid_kind(resources) -> true;
valid_kind(prompts) -> true;
valid_kind(_) -> false.

notification_method(tools) -> <<"notifications/tools/list_changed">>;
notification_method(resources) -> <<"notifications/resources/list_changed">>;
notification_method(prompts) -> <<"notifications/prompts/list_changed">>.

bounded_list(List, Max) -> bounded_list(List, Max, 0).
bounded_list([], _Max, _Count) -> true;
bounded_list([_ | Rest], Max, Count) when Count < Max ->
    bounded_list(Rest, Max, Count + 1);
bounded_list(_, _Max, _Count) -> false.

drop(List, 0) -> List;
drop([_ | Rest], Count) -> drop(Rest, Count - 1).

take(Rest, 0, Acc) -> {lists:reverse(Acc), Rest};
take([], _Count, Acc) -> {lists:reverse(Acc), []};
take([Head | Rest], Count, Acc) ->
    take(Rest, Count - 1, [Head | Acc]).

maybe_put(_Key, undefined, Map) -> Map;
maybe_put(Key, Value, Map) -> Map#{Key => Value}.

base64url(Binary) ->
    NoPadding = binary:replace(base64:encode(Binary), <<"=">>, <<>>,
                               [global]),
    binary:replace(binary:replace(NoPadding, <<"+">>, <<"-">>, [global]),
                   <<"/">>, <<"_">>, [global]).

base64url_decode(Binary) ->
    Standard = binary:replace(binary:replace(Binary, <<"-">>, <<"+">>,
                                             [global]),
                              <<"_">>, <<"/">>, [global]),
    Padding = case byte_size(Standard) rem 4 of
        0 -> <<>>;
        2 -> <<"==">>;
        3 -> <<"=">>;
        _ -> erlang:error(badarg)
    end,
    base64:decode(<<Standard/binary, Padding/binary>>).
