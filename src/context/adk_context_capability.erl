%% @doc Owner-bound, scope-bound authority used by invocation contexts.
%%
%% The service handles remain in this process. Tools receive only a random
%% token granting a validated subset of operations. Effects are correlated by
%% call ID and may be drained only by the invocation owner for event commit.
-module(adk_context_capability).
-behaviour(gen_server).

-export([start/2, start_link/2, root/1, delegate/4, call/4, take_effects/2,
         prepare_effects/2, commit_effects/2, abort_effects/2,
         resolve_attachment/4, stop/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(MAX_TOKENS, 1024).
-define(MAX_EFFECTS, 1024).
-define(MAX_ATTACHMENT_BYTES, 10485760).

-record(state, {
    owner :: pid(),
    owner_monitor :: reference(),
    root_token :: reference(),
    tokens = #{} :: map(),
    spec = #{} :: map(),
    effects = [] :: [map()],
    prepared_effects = #{} :: map(),
    attachments = #{} :: map(),
    attachment_bytes = 0 :: non_neg_integer()
}).

-type capability() :: {pid(), reference()}.
-export_type([capability/0]).

-spec start(pid(), map()) -> gen_server:start_ret().
start(Owner, Spec) ->
    gen_server:start(?MODULE, {Owner, Spec}, []).

-spec start_link(pid(), map()) -> gen_server:start_ret().
start_link(Owner, Spec) ->
    gen_server:start_link(?MODULE, {Owner, Spec}, []).

-spec root(pid()) -> {ok, capability()} | {error, term()}.
root(Pid) when is_pid(Pid) ->
    safe_call(Pid, root);
root(_) ->
    {error, invalid_context_capability}.

-spec delegate(capability(), [atom()], term(), pos_integer()) ->
    {ok, capability()} | {error, term()}.
delegate({Pid, RootToken}, Ops, CallId, Timeout)
  when is_pid(Pid), is_reference(RootToken), is_list(Ops),
       is_integer(Timeout), Timeout > 0 ->
    safe_call(Pid, {delegate, RootToken, Ops, CallId}, Timeout);
delegate(_, _, _, _) ->
    {error, invalid_context_capability}.

-spec call(capability(), atom(), term(), pos_integer()) -> term().
call({Pid, Token}, Operation, Request, Timeout)
  when is_pid(Pid), is_reference(Token), is_atom(Operation),
       is_integer(Timeout), Timeout > 0 ->
    safe_call(Pid, {operation, Token, Operation, Request}, Timeout);
call(_, _, _, _) ->
    {error, invalid_context_capability}.

-spec take_effects(capability(), term()) -> {ok, [map()]} | {error, term()}.
take_effects({Pid, RootToken}, CallId)
  when is_pid(Pid), is_reference(RootToken) ->
    safe_call(Pid, {take_effects, RootToken, CallId});
take_effects(_, _) ->
    {error, invalid_context_capability}.

-spec prepare_effects(capability(), term()) ->
    {ok, none | reference(), [map()]} | {error, term()}.
prepare_effects({Pid, RootToken}, CallId)
  when is_pid(Pid), is_reference(RootToken) ->
    safe_call(Pid, {prepare_effects, RootToken, CallId});
prepare_effects(_, _) -> {error, invalid_context_capability}.

-spec commit_effects(capability(), reference()) -> ok | {error, term()}.
commit_effects({Pid, RootToken}, Receipt)
  when is_pid(Pid), is_reference(RootToken), is_reference(Receipt) ->
    safe_call(Pid, {commit_effects, RootToken, Receipt});
commit_effects(_, _) -> {error, invalid_context_effect_receipt}.

-spec abort_effects(capability(), reference()) -> ok | {error, term()}.
abort_effects({Pid, RootToken}, Receipt)
  when is_pid(Pid), is_reference(RootToken), is_reference(Receipt) ->
    safe_call(Pid, {abort_effects, RootToken, Receipt});
abort_effects(_, _) -> {error, invalid_context_effect_receipt}.

-spec resolve_attachment(capability(), binary(), pos_integer(),
                         pos_integer()) ->
    {ok, map()} | {error, term()}.
resolve_attachment({Pid, RootToken}, Name, Version, Timeout)
  when is_pid(Pid), is_reference(RootToken), is_binary(Name),
       is_integer(Version), Version > 0,
       is_integer(Timeout), Timeout > 0 ->
    safe_call(Pid, {resolve_attachment, RootToken, Name, Version}, Timeout);
resolve_attachment(_, _, _, _) ->
    {error, invalid_context_capability}.

-spec stop(pid()) -> ok.
stop(Pid) when is_pid(Pid) ->
    gen_server:cast(Pid, stop),
    ok;
stop(_) -> ok.

init({Owner, Spec}) when is_pid(Owner), is_map(Spec) ->
    case normalize_spec(Spec) of
        {ok, SafeSpec} ->
            RootToken = make_ref(),
            Monitor = erlang:monitor(process, Owner),
            RootGrant = #{operations => all, call_id => root},
            {ok, #state{owner = Owner,
                        owner_monitor = Monitor,
                        root_token = RootToken,
                        tokens = #{RootToken => RootGrant},
                        spec = SafeSpec}};
        {error, Reason} ->
            {stop, Reason}
    end.

handle_call(root, {From, _}, #state{owner = From,
                                    root_token = Token} = State) ->
    {reply, {ok, {self(), Token}}, State};
handle_call(root, _From, State) ->
    {reply, {error, context_capability_owner_required}, State};
handle_call({delegate, RootToken, Ops0, CallId}, {From, _},
            #state{owner = From, root_token = RootToken,
                   tokens = Tokens} = State) ->
    case {normalize_operations(Ops0), map_size(Tokens) < ?MAX_TOKENS} of
        {{ok, Ops}, true} ->
            Token = make_ref(),
            Grant = #{operations => Ops, call_id => CallId},
            {reply, {ok, {self(), Token}},
             State#state{tokens = Tokens#{Token => Grant}}};
        {{error, _} = Error, _} ->
            {reply, Error, State};
        {_, false} ->
            {reply, {error, context_capability_limit}, State}
    end;
handle_call({delegate, _RootToken, _Ops, _CallId}, _From, State) ->
    {reply, {error, context_capability_owner_required}, State};
handle_call({operation, Token, Operation, Request}, _From,
            #state{tokens = Tokens} = State) ->
    case maps:find(Token, Tokens) of
        {ok, Grant} ->
            case operation_allowed(Operation, maps:get(operations, Grant)) of
                true -> execute_operation(Operation, Request, Grant, State);
                false ->
                    {reply, {error, {context_capability_denied, Operation}},
                     State}
            end;
        error ->
            {reply, {error, invalid_context_capability_token}, State}
    end;
handle_call({take_effects, RootToken, CallId}, {From, _},
            #state{owner = From, root_token = RootToken,
                   effects = Effects, tokens = Tokens,
                   prepared_effects = Prepared} = State) ->
    case lists:member(CallId, maps:values(Prepared)) of
        true ->
            {reply, {error, context_effects_already_prepared}, State};
        false ->
            {Selected, Remaining} = lists:partition(
                                      fun(#{call_id := Seen}) ->
                                              Seen =:= CallId
                                      end, Effects),
            Public = [maps:remove(call_id, Effect)
                      || Effect <- lists:reverse(Selected)],
            %% Compatibility drain remains atomic. Runner uses the staged
            %% prepare/commit protocol so persistence happens between them.
            RemainingTokens = revoke_call_tokens(
                                Tokens, RootToken, CallId),
            {reply, {ok, Public},
             State#state{effects = Remaining,
                         tokens = RemainingTokens}}
    end;
handle_call({take_effects, _RootToken, _CallId}, _From, State) ->
    {reply, {error, context_capability_owner_required}, State};
handle_call({prepare_effects, RootToken, CallId}, {From, _},
            #state{owner = From, root_token = RootToken,
                   effects = Effects, tokens = Tokens,
                   prepared_effects = Prepared} = State) ->
    case lists:any(fun({_Receipt, SeenCallId}) ->
                           SeenCallId =:= CallId
                   end, maps:to_list(Prepared)) of
        true ->
            {reply, {error, context_effects_already_prepared}, State};
        false ->
            Selected = [Effect || Effect = #{call_id := Seen} <- Effects,
                                  Seen =:= CallId],
            Public = [maps:remove(call_id, Effect)
                      || Effect <- lists:reverse(Selected)],
            RemainingTokens = revoke_call_tokens(
                                Tokens, RootToken, CallId),
            case Selected of
                [] ->
                    {reply, {ok, none, []},
                     State#state{tokens = RemainingTokens}};
                _ ->
                    Receipt = make_ref(),
                    {reply, {ok, Receipt, Public},
                     State#state{
                       tokens = RemainingTokens,
                       prepared_effects = Prepared#{Receipt => CallId}}}
            end
    end;
handle_call({prepare_effects, _RootToken, _CallId}, _From, State) ->
    {reply, {error, context_capability_owner_required}, State};
handle_call({commit_effects, RootToken, Receipt}, {From, _},
            #state{owner = From, root_token = RootToken,
                   effects = Effects,
                   prepared_effects = Prepared} = State) ->
    case maps:take(Receipt, Prepared) of
        {CallId, RemainingPrepared} ->
            RemainingEffects = [Effect || Effect = #{call_id := Seen}
                                             <- Effects,
                                          Seen =/= CallId],
            {reply, ok,
             State#state{effects = RemainingEffects,
                         prepared_effects = RemainingPrepared}};
        error ->
            {reply, {error, invalid_context_effect_receipt}, State}
    end;
handle_call({commit_effects, _RootToken, _Receipt}, _From, State) ->
    {reply, {error, context_capability_owner_required}, State};
handle_call({abort_effects, RootToken, Receipt}, {From, _},
            #state{owner = From, root_token = RootToken,
                   prepared_effects = Prepared} = State) ->
    case maps:take(Receipt, Prepared) of
        {_CallId, RemainingPrepared} ->
            %% The service mutation may already have committed. Keep its
            %% correlated effect available for an explicit retry/recovery
            %% event instead of discarding it before persistence succeeds.
            {reply, ok,
             State#state{prepared_effects = RemainingPrepared}};
        error ->
            {reply, {error, invalid_context_effect_receipt}, State}
    end;
handle_call({abort_effects, _RootToken, _Receipt}, _From, State) ->
    {reply, {error, context_capability_owner_required}, State};
handle_call({resolve_attachment, RootToken, Name, Version}, {From, _},
            #state{owner = From, root_token = RootToken,
                   attachments = Attachments} = State) ->
    Reply = case maps:find({Name, Version}, Attachments) of
        {ok, Artifact} -> {ok, Artifact};
        error -> {error, artifact_attachment_not_found}
    end,
    {reply, Reply, State};
handle_call({resolve_attachment, _RootToken, _Name, _Version}, _From,
            State) ->
    {reply, {error, context_capability_owner_required}, State};
handle_call(_Request, _From, State) ->
    {reply, {error, unsupported_context_capability_request}, State}.

handle_cast(stop, State) ->
    {stop, normal, State};
handle_cast(_Message, State) ->
    {noreply, State}.

handle_info({'DOWN', Monitor, process, Owner, _Reason},
            #state{owner = Owner, owner_monitor = Monitor} = State) ->
    {stop, normal, State};
handle_info(_Message, State) ->
    {noreply, State}.

terminate(_Reason, _State) -> ok.
code_change(_OldVersion, State, _Extra) -> {ok, State}.

normalize_spec(Spec) ->
    Allowed = [identity, session_service, artifact_service, artifact_scope,
               memory_service, memory_scope, timeout],
    Unknown = maps:keys(maps:without(Allowed, Spec)),
    Timeout = maps:get(timeout, Spec, 5000),
    case {Unknown, is_integer(Timeout) andalso Timeout > 0,
          valid_identity(maps:get(identity, Spec, #{})),
          valid_optional_service(maps:get(artifact_service, Spec, undefined)),
          valid_optional_service(maps:get(memory_service, Spec, undefined)),
          valid_optional_session_service(
            maps:get(session_service, Spec, undefined))} of
        {[], true, true, true, true, true} ->
            {ok, Spec#{timeout => Timeout,
                       session_service => maps:get(
                                            session_service, Spec,
                                            undefined),
                       artifact_service => maps:get(
                                            artifact_service, Spec,
                                            undefined),
                       memory_service => maps:get(
                                          memory_service, Spec,
                                          undefined),
                       artifact_scope => maps:get(
                                           artifact_scope, Spec,
                                           undefined),
                       memory_scope => maps:get(memory_scope, Spec,
                                                undefined)}};
        {[_ | _], _, _, _, _, _} ->
            {error, {unknown_context_capability_options,
                     lists:sort(Unknown)}};
        {_, false, _, _, _, _} -> {error, invalid_context_capability_timeout};
        {_, _, false, _, _, _} -> {error, invalid_context_identity};
        {_, _, _, false, _, _} -> {error, invalid_artifact_service};
        {_, _, _, _, false, _} -> {error, invalid_memory_service};
        _ -> {error, invalid_session_service}
    end.

valid_identity(Identity) when is_map(Identity) ->
    Required = [app_name, user_id, session_id, invocation_id],
    lists:all(fun(Key) ->
                      Value = maps:get(Key, Identity, undefined),
                      is_binary(Value) andalso byte_size(Value) > 0
              end, Required);
valid_identity(_) -> false.

valid_optional_service(undefined) -> true;
valid_optional_service({Module, Handle}) ->
    is_atom(Module) andalso Handle =/= undefined;
valid_optional_service(_) -> false.

valid_optional_session_service(undefined) -> true;
valid_optional_session_service(Module) -> is_atom(Module).

allowed_operations() ->
    [identity, state_read,
     artifact_put, artifact_get, artifact_list, artifact_list_versions,
     artifact_delete, artifact_attach,
     memory_search, memory_add, memory_delete].

normalize_operations(Ops) ->
    case lists:all(fun(Op) -> lists:member(Op, allowed_operations()) end,
                   Ops) of
        true -> {ok, lists:usort(Ops)};
        false -> {error, invalid_context_capability_operations}
    end.

operation_allowed(_Operation, all) -> true;
operation_allowed(Operation, Operations) -> lists:member(Operation, Operations).

execute_operation(identity, _Request, _Grant,
                  #state{spec = Spec} = State) ->
    {reply, {ok, maps:get(identity, Spec)}, State};
execute_operation(state_read, _Request, _Grant,
                  #state{spec = Spec} = State) ->
    Reply = read_state(Spec),
    {reply, Reply, State};
execute_operation(Operation, Request, Grant, State)
  when Operation =:= artifact_put; Operation =:= artifact_get;
       Operation =:= artifact_list; Operation =:= artifact_list_versions;
       Operation =:= artifact_delete; Operation =:= artifact_attach ->
    execute_artifact(Operation, Request, Grant, State);
execute_operation(Operation, Request, Grant, State)
  when Operation =:= memory_search; Operation =:= memory_add;
       Operation =:= memory_delete ->
    execute_memory(Operation, Request, Grant, State);
execute_operation(Operation, _Request, _Grant, State) ->
    {reply, {error, {unsupported_context_operation, Operation}}, State}.

read_state(#{session_service := Module,
             identity := #{app_name := App, user_id := User,
                           session_id := Session}}) ->
    try Module:get_session(App, User, Session) of
        {ok, Stored} when is_map(Stored) ->
            {ok, maps:get(state, Stored, #{})};
        {error, _} = Error -> Error;
        Other -> {error, {invalid_session_reply, Other}}
    catch
        Class:Reason -> {error, {session_exception, Class, Reason}}
    end;
read_state(_) -> {error, session_service_unavailable}.

execute_artifact(_Operation, _Request, _Grant,
                 #state{spec = #{artifact_service := undefined}} = State) ->
    {reply, {error, artifact_service_unavailable}, State};
execute_artifact(Operation, Request, Grant,
                 #state{spec = Spec} = State) ->
    case effect_capacity(Operation, State) of
        full -> {reply, {error, context_effect_limit}, State};
        available ->
            Service = maps:get(artifact_service, Spec),
            Scope = maps:get(artifact_scope, Spec, undefined),
            Timeout = maps:get(timeout, Spec),
            case artifact_call(Operation, Service, Scope, Request, Timeout) of
                {Reply, none} -> {reply, Reply, State};
                {Reply, Effect} ->
                    add_effect_reply(Reply, Effect, Grant, State)
            end
    end.

artifact_call(artifact_put, {Module, _} = Service, Scope,
              #{name := Name, data := Data, options := Options}, Timeout) ->
    RawReply = case erlang:function_exported(Module, put, 6) of
        true -> adk_service_ref:call(
                  Service, put,
                  [Scope, Name, Data, Options,
                   #{timeout_ms => operation_timeout(Timeout)}], Timeout);
        false -> {error, artifact_deadline_unsupported}
    end,
    Reply = validate_artifact_item_reply(RawReply, Scope, Name),
    Effect = case Reply of
        {ok, Metadata} when is_map(Metadata) ->
            #{kind => artifact_delta,
              operation => put,
              scope => Scope,
              name => Name,
              version => maps:get(version, Metadata, undefined),
              digest => maps:get(digest, Metadata, undefined),
              size => maps:get(size, Metadata, undefined),
              mime_type => maps:get(mime_type, Metadata, undefined)};
        _ -> none
    end,
    {Reply, Effect};
artifact_call(artifact_get, {Module, _} = Service, Scope,
              #{name := Name, selector := Selector}, Timeout) ->
    {validate_artifact_item_reply(
       artifact_get_call(Module, Service, Scope, Name, Selector, Timeout),
       Scope, Name),
     none};
artifact_call(artifact_attach, {Module, _} = Service, Scope,
              #{name := Name, selector := Selector}, Timeout) ->
    case artifact_get_call(
           Module, Service, Scope, Name, Selector, Timeout) of
        {ok, Artifact} when is_map(Artifact) ->
            case validate_attachment_artifact(Artifact, Scope, Name) of
                {ok, Canonical} ->
                    Effect = #{kind => artifact_attachment,
                               scope => Scope,
                               name => Name,
                               version => maps:get(version, Canonical),
                               digest => maps:get(digest, Canonical),
                               mime_type => maps:get(mime_type, Canonical),
                               size => maps:get(size, Canonical),
                               attachment => Canonical},
                    {{ok, maps:remove(data, Canonical)}, Effect};
                {error, _} = Error -> {Error, none}
            end;
        {ok, _Other} -> {{error, invalid_artifact_service_reply}, none};
        {error, _} = Error -> {Error, none};
        _Other -> {{error, invalid_artifact_service_reply}, none}
    end;
artifact_call(artifact_list, Service, Scope, Request, Timeout) ->
    artifact_list_call(Service, Scope, Request, Timeout);
artifact_call(artifact_list_versions, Service, Scope,
              #{name := Name} = Request, Timeout) ->
    artifact_versions_call(Service, Scope, Name, Request, Timeout);
artifact_call(artifact_delete, {Module, _} = Service, Scope,
              #{name := Name, selector := Selector}, Timeout) ->
    Reply = case erlang:function_exported(Module, delete, 5) of
        true -> adk_service_ref:call(
                  Service, delete,
                  [Scope, Name, Selector,
                   #{timeout_ms => operation_timeout(Timeout)}], Timeout);
        false -> {error, artifact_deadline_unsupported}
    end,
    Effect = case Reply of
        ok -> #{kind => artifact_delta, operation => delete,
                scope => Scope, name => Name,
                version => case Selector of
                    Version when is_integer(Version) -> Version;
                    _ -> undefined
                end};
        _ -> none
    end,
    {Reply, Effect};
artifact_call(_Operation, _Service, _Scope, _Request, _Timeout) ->
    {{error, invalid_context_artifact_request}, none}.

artifact_get_call(Module, Service, Scope, Name, Selector, Timeout) ->
    case erlang:function_exported(Module, get, 5) of
        true -> adk_service_ref:call(
                  Service, get,
                  [Scope, Name, Selector,
                   #{timeout_ms => operation_timeout(Timeout)}], Timeout);
        false -> adk_service_ref:call(
                   Service, get, [Scope, Name, Selector], Timeout)
    end.

operation_timeout(Timeout) when Timeout > 250 -> Timeout - 200;
operation_timeout(Timeout) -> erlang:max(1, Timeout div 2).

artifact_list_call({Module, Handle} = Service, Scope, Request, Timeout) ->
    case erlang:function_exported(Module, list_names, 3) of
        true ->
            Reply = adk_service_ref:call(Service, list_names,
                                         [Scope, Request], Timeout),
            {validate_artifact_name_page_reply(Reply, Scope), none};
        false ->
            Reply = adk_service_ref:call(
                      {Module, Handle}, list, [Scope], Timeout),
            {validate_artifact_items_reply(Reply, Scope, any), none}
    end.

artifact_versions_call({Module, _Handle} = Service, Scope, Name,
                       Request, Timeout) ->
    case erlang:function_exported(Module, list_versions, 4) of
        true ->
            Reply = adk_service_ref:call(
                      Service, list_versions,
                      [Scope, Name, Request], Timeout),
            {validate_artifact_version_page_reply(
               Reply, Scope, Name), none};
        false ->
            RawReply = adk_service_ref:call(
                         Service, list, [Scope], Timeout),
            Reply = validate_artifact_items_reply(
                      RawReply, Scope, any),
            {legacy_versions(Reply, Name), none}
    end.

legacy_versions({ok, Items}, Name) when is_list(Items) ->
    {ok, [Item || Item <- Items,
                  is_map(Item), maps:get(name, Item, undefined) =:= Name]};
legacy_versions(Reply, _Name) -> Reply.

%% A capability is a tenant boundary, while adapters are replaceable and may
%% be buggy. Never rely only on the scope passed into an adapter call when the
%% reply carries its own scope/name provenance: validate that provenance before
%% returning data or recording an effect.
validate_artifact_item_reply({ok, Item} = Reply, Scope, Name)
  when is_map(Item) ->
    case valid_artifact_identity(Item, Scope, Name) of
        true -> Reply;
        false -> {error, invalid_artifact_service_reply}
    end;
validate_artifact_item_reply({ok, _Other}, _Scope, _Name) ->
    {error, invalid_artifact_service_reply};
validate_artifact_item_reply({error, _} = Error, _Scope, _Name) -> Error;
validate_artifact_item_reply(_Other, _Scope, _Name) ->
    {error, invalid_artifact_service_reply}.

validate_artifact_items_reply({ok, Items} = Reply, Scope, Name)
  when is_list(Items) ->
    case lists:all(
           fun(Item) -> valid_artifact_identity(Item, Scope, Name) end,
           Items) of
        true -> Reply;
        false -> {error, invalid_artifact_service_reply}
    end;
validate_artifact_items_reply({ok, _Other}, _Scope, _Name) ->
    {error, invalid_artifact_service_reply};
validate_artifact_items_reply({error, _} = Error, _Scope, _Name) -> Error;
validate_artifact_items_reply(_Other, _Scope, _Name) ->
    {error, invalid_artifact_service_reply}.

validate_artifact_name_page_reply(
  {ok, #{scope := Scope, items := Items,
         next_cursor := Cursor}} = Reply, Scope)
  when is_list(Items) ->
    ValidItems = lists:all(
                   fun(Name) ->
                       adk_artifact_core:validate_name(Name) =:= ok
                   end, Items),
    ValidCursor = Cursor =:= undefined orelse
                  adk_artifact_core:validate_name(Cursor) =:= ok,
    case ValidItems andalso ValidCursor of
        true -> Reply;
        false -> {error, invalid_artifact_service_reply}
    end;
validate_artifact_name_page_reply({ok, _Other}, _Scope) ->
    {error, invalid_artifact_service_reply};
validate_artifact_name_page_reply({error, _} = Error, _Scope) -> Error;
validate_artifact_name_page_reply(_Other, _Scope) ->
    {error, invalid_artifact_service_reply}.

validate_artifact_version_page_reply(
  {ok, #{items := Items, next_cursor := Cursor}} = Reply, Scope, Name)
  when is_list(Items) ->
    ValidCursor = Cursor =:= undefined orelse
                  (is_integer(Cursor) andalso Cursor > 0),
    case ValidCursor andalso
         lists:all(
           fun(Item) -> valid_artifact_identity(Item, Scope, Name) end,
           Items) of
        true -> Reply;
        false -> {error, invalid_artifact_service_reply}
    end;
validate_artifact_version_page_reply({ok, _Other}, _Scope, _Name) ->
    {error, invalid_artifact_service_reply};
validate_artifact_version_page_reply(
  {error, _} = Error, _Scope, _Name) -> Error;
validate_artifact_version_page_reply(_Other, _Scope, _Name) ->
    {error, invalid_artifact_service_reply}.

valid_artifact_identity(Item, Scope, any) when is_map(Item) ->
    maps:get(scope, Item, undefined) =:= Scope andalso
    adk_artifact_core:validate_name(
      maps:get(name, Item, undefined)) =:= ok;
valid_artifact_identity(Item, Scope, Name) when is_map(Item) ->
    maps:get(scope, Item, undefined) =:= Scope andalso
    maps:get(name, Item, undefined) =:= Name andalso
    adk_artifact_core:validate_name(Name) =:= ok;
valid_artifact_identity(_Item, _Scope, _Name) -> false.

validate_attachment_artifact(Artifact, Scope, Name) ->
    Data = maps:get(data, Artifact, undefined),
    Version = maps:get(version, Artifact, undefined),
    MimeType = maps:get(mime_type, Artifact, undefined),
    Digest = maps:get(digest, Artifact, undefined),
    Size = maps:get(size, Artifact, undefined),
    Valid = maps:get(scope, Artifact, undefined) =:= Scope andalso
            maps:get(name, Artifact, undefined) =:= Name andalso
            is_integer(Version) andalso Version > 0 andalso
            is_binary(Data) andalso byte_size(Data) =< ?MAX_ATTACHMENT_BYTES andalso
            is_binary(MimeType) andalso byte_size(MimeType) > 0 andalso
            is_integer(Size) andalso Size =:= byte_size(Data) andalso
            is_binary(Digest) andalso
            Digest =:= hex_digest(Data),
    case Valid of
        true -> {ok, Artifact};
        false -> {error, invalid_artifact_service_reply}
    end.

hex_digest(Data) ->
    iolist_to_binary([io_lib:format("~2.16.0b", [Byte])
                      || <<Byte>> <= crypto:hash(sha256, Data)]).

execute_memory(_Operation, _Request, _Grant,
               #state{spec = #{memory_service := undefined}} = State) ->
    {reply, {error, memory_service_unavailable}, State};
execute_memory(Operation, Request, Grant, #state{spec = Spec} = State) ->
    case effect_capacity(Operation, State) of
        full -> {reply, {error, context_effect_limit}, State};
        available ->
            Service = maps:get(memory_service, Spec),
            Scope = maps:get(memory_scope, Spec, undefined),
            Timeout = maps:get(timeout, Spec),
            case memory_call(Operation, Service, Scope, Request, Timeout) of
                {Reply, none} -> {reply, Reply, State};
                {Reply, Effect} -> add_effect_reply(Reply, Effect, Grant, State)
            end
    end.

effect_capacity(Operation, #state{effects = Effects})
  when Operation =:= artifact_put; Operation =:= artifact_attach;
       Operation =:= artifact_delete; Operation =:= memory_add;
       Operation =:= memory_delete ->
    case length(Effects) < ?MAX_EFFECTS of
        true -> available;
        false -> full
    end;
effect_capacity(_Operation, _State) -> available.

memory_call(memory_search, {Module, _} = Service, Scope,
            #{query := Query, options := Options}, Timeout) ->
    case erlang:function_exported(Module, search, 4) of
        true ->
            %% V2 and legacy share arity 4. A tagged user scope identifies V2;
            %% legacy fallback is used only when capabilities do not advertise
            %% scoped memory.
            case memory_v2(Module, Service, Timeout) of
                true ->
                    RawReply = case erlang:function_exported(
                                          Module, search, 5) of
                        true -> adk_service_ref:call(
                                  Service, search,
                                  [Scope, Query, Options,
                                   #{timeout_ms => operation_timeout(Timeout)}],
                                  Timeout);
                        false -> adk_service_ref:call(
                                   Service, search,
                                   [Scope, Query, Options], Timeout)
                    end,
                    {validate_memory_items_reply(RawReply, Scope),
                     none};
                false ->
                    {{error, scoped_memory_v2_required}, none};
                {error, Reason} -> {{error, Reason}, none}
            end;
        false -> {{error, memory_search_unsupported}, none}
    end;
memory_call(memory_add, {Module, _} = Service, Scope,
            #{entry := Entry, options := Options}, Timeout) ->
    case erlang:function_exported(Module, add_entry, 5) of
        true ->
            RawReply = adk_service_ref:call(
                         Service, add_entry,
                         [Scope, Entry, Options,
                          #{timeout_ms => operation_timeout(Timeout)}],
                         Timeout),
            Reply = validate_memory_item_reply(RawReply, Scope),
            Effect = case Reply of
                {ok, Metadata} -> #{kind => memory_delta,
                                    operation => add,
                                    scope => Scope,
                                    entry => effect_entry(Metadata)};
                _ -> none
            end,
            {Reply, Effect};
        false -> {{error, memory_deadline_unsupported}, none}
    end;
memory_call(memory_delete, {Module, _} = Service, Scope,
            #{id := Id}, Timeout) ->
    case erlang:function_exported(Module, delete_entry, 4) of
        true ->
            Reply = adk_service_ref:call(
                      Service, delete_entry,
                      [Scope, Id,
                       #{timeout_ms => operation_timeout(Timeout)}],
                      Timeout),
            Effect = case Reply of
                ok -> #{kind => memory_delta, operation => delete,
                        scope => Scope, entry => #{id => Id}};
                _ -> none
            end,
            {Reply, Effect};
        false -> {{error, memory_deadline_unsupported}, none}
    end;
memory_call(_Operation, _Service, _Scope, _Request, _Timeout) ->
    {{error, invalid_context_memory_request}, none}.

validate_memory_item_reply({ok, Item} = Reply, Scope) when is_map(Item) ->
    case maps:get(scope, Item, undefined) =:= Scope of
        true -> Reply;
        false -> {error, invalid_memory_service_reply}
    end;
validate_memory_item_reply({ok, _Other}, _Scope) ->
    {error, invalid_memory_service_reply};
validate_memory_item_reply({error, _} = Error, _Scope) -> Error;
validate_memory_item_reply(_Other, _Scope) ->
    {error, invalid_memory_service_reply}.

validate_memory_items_reply({ok, Items} = Reply, Scope)
  when is_list(Items) ->
    case lists:all(
           fun(Item) ->
               is_map(Item) andalso
               maps:get(scope, Item, undefined) =:= Scope
           end, Items) of
        true -> Reply;
        false -> {error, invalid_memory_service_reply}
    end;
validate_memory_items_reply({ok, _Other}, _Scope) ->
    {error, invalid_memory_service_reply};
validate_memory_items_reply({error, _} = Error, _Scope) -> Error;
validate_memory_items_reply(_Other, _Scope) ->
    {error, invalid_memory_service_reply}.

memory_v2(Module, Service, Timeout) ->
    case erlang:function_exported(Module, capabilities, 1) of
        false -> false;
        true ->
            case adk_service_ref:call(Service, capabilities, [], Timeout) of
                #{contract_version := Version} when Version >= 2 -> true;
                {ok, #{contract_version := Version}} when Version >= 2 -> true;
                %% Accept the short key from early 0.5 adapter prototypes.
                #{version := Version} when Version >= 2 -> true;
                {ok, #{version := Version}} when Version >= 2 -> true;
                #{contract_version := _} -> false;
                {ok, #{contract_version := _}} -> false;
                {error, Reason} -> {error, {memory_capabilities_failed,
                                            Reason}};
                Other -> {error, {invalid_memory_capabilities, Other}}
            end
    end.

effect_entry(#{id := Id}) -> #{id => Id};
effect_entry(_) -> #{}.

add_effect_reply(Reply, Effect, Grant,
                 #state{effects = Effects} = State) ->
    case length(Effects) < ?MAX_EFFECTS of
        true ->
            case prepare_effect_storage(Effect, State) of
                {ok, PublicEffect, PreparedState} ->
                    Stored = PublicEffect#{
                               call_id => maps:get(call_id, Grant)},
                    {reply, Reply,
                     PreparedState#state{effects = [Stored | Effects]}};
                {error, Reason} ->
                    {reply, {error, Reason}, State}
            end;
        false ->
            {reply, {error, context_effect_limit}, State}
    end.

%% Attachment bytes are invocation-private and never become event actions.
%% Keep the exact bytes that were validated when attach_artifact/3 completed,
%% so the next model request cannot observe a deleted or replaced artifact.
prepare_effect_storage(
  #{kind := artifact_attachment, attachment := Artifact} = Effect,
  #state{attachments = Attachments,
         attachment_bytes = AttachmentBytes} = State) ->
    Name = maps:get(name, Effect),
    Version = maps:get(version, Effect),
    Data = maps:get(data, Artifact),
    Key = {Name, Version},
    PreviousBytes = case maps:find(Key, Attachments) of
        {ok, Previous} -> byte_size(maps:get(data, Previous));
        error -> 0
    end,
    NewBytes = AttachmentBytes - PreviousBytes + byte_size(Data),
    case NewBytes =< ?MAX_ATTACHMENT_BYTES of
        true ->
            {ok, maps:remove(attachment, Effect),
             State#state{attachments = Attachments#{Key => Artifact},
                         attachment_bytes = NewBytes}};
        false ->
            {error, {artifact_attachment_bytes_exceeded,
                     NewBytes, ?MAX_ATTACHMENT_BYTES}}
    end;
prepare_effect_storage(Effect, State) ->
    {ok, Effect, State}.

revoke_call_tokens(Tokens, RootToken, CallId) ->
    maps:filter(
      fun(Token, Grant) ->
          Token =:= RootToken orelse maps:get(call_id, Grant) =/= CallId
      end, Tokens).

safe_call(Pid, Request) -> safe_call(Pid, Request, 5000).

safe_call(Pid, Request, Timeout) ->
    try gen_server:call(Pid, Request, Timeout) of
        Reply -> Reply
    catch
        exit:{timeout, _} -> {error, context_capability_timeout};
        exit:{noproc, _} -> {error, context_capability_unavailable};
        exit:Reason -> {error, {context_capability_failed, Reason}}
    end.
