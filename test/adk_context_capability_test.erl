-module(adk_context_capability_test).

-include_lib("eunit/include/eunit.hrl").

-export([capabilities/1,
         put/5, put/6, get/4, get/5, list/2, list_names/3,
         list_versions/4, delete/4, delete/5,
         add_entry/4, add_entry/5, add_events/5,
         add_session_to_memory/5, search/4, search/5,
         delete_entry/3, delete_entry/4, delete_session/3,
         delete_user/2]).

-define(APP, <<"context-capability-app">>).
-define(USER, <<"context-capability-user">>).
-define(SESSION, <<"context-capability-session">>).
-define(INVOCATION, <<"context-capability-invocation">>).

capability_test_() ->
    [?_test(with_state(fun scoped_operation_and_effect/1)),
     ?_test(with_state(fun declared_projection_is_least_authority/1)),
     ?_test(with_state(fun owner_only_delegation_and_effect_drain/1)),
     ?_test(with_state(fun staged_effect_commit_and_attachment_snapshot/1)),
     ?_test(hostile_artifact_responses_fail_closed()),
     ?_test(hostile_memory_responses_fail_closed()),
     ?_test(owner_death_stops_capability())].

with_state(Test) ->
    State = setup(),
    try Test(State)
    after cleanup(State)
    end.

setup() ->
    {ok, ArtifactPid} = adk_artifact_ets:start_link(#{}),
    Spec = #{identity => identity(),
             artifact_service => {adk_artifact_ets, ArtifactPid},
             artifact_scope => scope(),
             timeout => 1000},
    {ok, CapabilityPid} = adk_context_capability:start(self(), Spec),
    {ok, Root} = adk_context_capability:root(CapabilityPid),
    #{artifact_pid => ArtifactPid,
      capability_pid => CapabilityPid,
      root => Root}.

cleanup(#{artifact_pid := ArtifactPid, capability_pid := CapabilityPid}) ->
    adk_context_capability:stop(CapabilityPid),
    adk_artifact_ets:stop(ArtifactPid).

scoped_operation_and_effect(#{root := Root}) ->
    EffectId = make_ref(),
    {ok, Child} = adk_context_capability:delegate(
                    Root, [identity, artifact_put, artifact_get],
                    EffectId, 1000),
    Context = #{context_capability => Child},
    {ok, Metadata} = adk_context:save_artifact(
                       Context, <<"one.txt">>, <<"one">>,
                       #{mime_type => <<"text/plain">>}),
    ?assertEqual(scope(), maps:get(scope, Metadata)),
    {ok, Artifact} = adk_context:load_artifact(Context, <<"one.txt">>, latest),
    ?assertEqual(<<"one">>, maps:get(data, Artifact)),
    {ok, [Effect]} = adk_context_capability:take_effects(Root, EffectId),
    ?assertEqual(artifact_delta, maps:get(kind, Effect)),
    ?assertEqual(scope(), maps:get(scope, Effect)),
    ?assertEqual(<<"one.txt">>, maps:get(name, Effect)),
    {ok, []} = adk_context_capability:take_effects(Root, EffectId).

declared_projection_is_least_authority(#{root := Root}) ->
    EffectId = make_ref(),
    Raw = #{app_name => ?APP,
            user_id => ?USER,
            session_id => ?SESSION,
            invocation_id => ?INVOCATION,
            call_id => <<"call-1">>,
            '$adk_effect_id' => EffectId,
            artifact_service => should_not_escape,
            memory_service => should_not_escape,
            state_ref => should_not_escape},
    Runtime = #{context_capability => Root, service_timeout => 1000},
    {ok, Projected} = adk_context:project_tool(
                        adk_context_capability_tool, Raw, Runtime),
    ?assertNot(maps:is_key(artifact_service, Projected)),
    ?assertNot(maps:is_key(memory_service, Projected)),
    ?assertNot(maps:is_key(state_ref, Projected)),
    {ok, _} = adk_context:save_artifact(
                Projected, <<"projected.txt">>, <<"ok">>, #{}),
    ?assertEqual(
       {error, {context_capability_denied, artifact_get}},
       adk_context:load_artifact(Projected, <<"projected.txt">>, latest)),
    {ok, [_]} = adk_context_capability:take_effects(Root, EffectId).

owner_only_delegation_and_effect_drain(#{root := Root}) ->
    Parent = self(),
    Ref = make_ref(),
    spawn(fun() ->
        Parent ! {Ref,
                  adk_context_capability:delegate(
                    Root, [identity], none, 1000),
                  adk_context_capability:take_effects(Root, none)}
    end),
    receive
        {Ref, Delegate, Drain} ->
            ?assertEqual({error, context_capability_owner_required}, Delegate),
            ?assertEqual({error, context_capability_owner_required}, Drain)
    after 1000 ->
        ?assert(false)
    end.

staged_effect_commit_and_attachment_snapshot(
  #{root := Root, artifact_pid := ArtifactPid}) ->
    EffectId = make_ref(),
    {ok, Child} = adk_context_capability:delegate(
                    Root, [artifact_put, artifact_attach], EffectId, 1000),
    Context = #{context_capability => Child},
    {ok, Metadata} = adk_context:save_artifact(
                       Context, <<"snapshot.txt">>, <<"snapshot bytes">>,
                       #{mime_type => <<"text/plain">>}),
    {ok, _PublicAttachment} = adk_context:attach_artifact(
                                Context, <<"snapshot.txt">>, latest),
    Version = maps:get(version, Metadata),
    ok = adk_artifact_ets:delete(
           ArtifactPid, scope(), <<"snapshot.txt">>, Version),
    {ok, Snapshot} = adk_context_capability:resolve_attachment(
                       Root, <<"snapshot.txt">>, Version, 1000),
    ?assertEqual(<<"snapshot bytes">>, maps:get(data, Snapshot)),
    {ok, Receipt1, Effects1} = adk_context_capability:prepare_effects(
                                Root, EffectId),
    ?assertEqual(2, length(Effects1)),
    ?assertEqual(
       {error, context_effects_already_prepared},
       adk_context_capability:take_effects(Root, EffectId)),
    ?assertEqual(
       {error, invalid_context_capability_token},
       adk_context:attach_artifact(Context, <<"snapshot.txt">>, Version)),
    ok = adk_context_capability:abort_effects(Root, Receipt1),
    {ok, Receipt2, Effects1} = adk_context_capability:prepare_effects(
                                Root, EffectId),
    ok = adk_context_capability:commit_effects(Root, Receipt2),
    {ok, none, []} = adk_context_capability:prepare_effects(Root, EffectId).

owner_death_stops_capability() ->
    Parent = self(),
    Owner = spawn(fun() ->
        {ok, Pid} = adk_context_capability:start(
                      self(), #{identity => identity(), timeout => 1000}),
        {ok, _Root} = adk_context_capability:root(Pid),
        Parent ! {owned_capability, self(), Pid},
        receive stop -> ok end
    end),
    CapPid = receive
        {owned_capability, Owner, Pid} -> Pid
    after 1000 -> error(capability_not_started)
    end,
    Monitor = erlang:monitor(process, CapPid),
    exit(Owner, kill),
    receive
        {'DOWN', Monitor, process, CapPid, normal} -> ok;
        {'DOWN', Monitor, process, CapPid, Reason} ->
            ?assertEqual(normal, Reason)
    after 1000 ->
        ?assert(false)
    end.

hostile_artifact_responses_fail_closed() ->
    Name = <<"foreign.txt">>,
    ForeignScope = {session, ?APP, <<"foreign-user">>, ?SESSION},
    ForeignMeta = #{scope => ForeignScope, name => Name, version => 1,
                    mime_type => <<"text/plain">>, digest => <<"digest">>,
                    size => 7, created_at => 1, metadata => #{}},
    Handle = #{artifact_put_reply => {ok, ForeignMeta},
               artifact_get_reply =>
                   {ok, ForeignMeta#{data => <<"foreign">>}},
               artifact_names_reply =>
                   {ok, #{scope => ForeignScope,
                          items => [<<"foreign.txt">>],
                          next_cursor => undefined}},
               artifact_versions_reply =>
                   {ok, #{items => [ForeignMeta],
                          next_cursor => undefined}}},
    Spec = #{identity => identity(),
             artifact_service => {?MODULE, Handle},
             artifact_scope => scope(), timeout => 1000},
    {ok, Pid} = adk_context_capability:start(self(), Spec),
    try
        {ok, Root} = adk_context_capability:root(Pid),
        EffectId = make_ref(),
        {ok, Child} = adk_context_capability:delegate(
                        Root,
                        [artifact_put, artifact_get, artifact_list,
                         artifact_list_versions], EffectId, 1000),
        Context = #{context_capability => Child},
        ?assertEqual(
           {error, invalid_artifact_service_reply},
           adk_context:save_artifact(Context, Name, <<"payload">>, #{})),
        ?assertEqual(
           {error, invalid_artifact_service_reply},
           adk_context:load_artifact(Context, Name, latest)),
        ?assertEqual(
           {error, invalid_artifact_service_reply},
           adk_context:list_artifacts(Context, #{limit => 5})),
        ?assertEqual(
           {error, invalid_artifact_service_reply},
           adk_context:list_artifact_versions(
             Context, Name, #{limit => 5})),
        ?assertEqual(
           {ok, []},
           adk_context_capability:take_effects(Root, EffectId))
    after
        adk_context_capability:stop(Pid)
    end.

hostile_memory_responses_fail_closed() ->
    ForeignScope = {user, ?APP, <<"foreign-user">>},
    ForeignEntry = #{scope => ForeignScope, id => <<"foreign-entry">>,
                     content => <<"foreign memory">>},
    Handle = #{memory_add_reply => {ok, ForeignEntry},
               memory_search_reply => {ok, [ForeignEntry]}},
    Spec = #{identity => identity(),
             memory_service => {?MODULE, Handle},
             memory_scope => memory_scope(), timeout => 1000},
    {ok, Pid} = adk_context_capability:start(self(), Spec),
    try
        {ok, Root} = adk_context_capability:root(Pid),
        EffectId = make_ref(),
        {ok, Child} = adk_context_capability:delegate(
                        Root, [memory_add, memory_search], EffectId, 1000),
        Context = #{context_capability => Child},
        ?assertEqual(
           {error, invalid_memory_service_reply},
           adk_context:add_memory(
             Context, #{content => <<"remember">>}, #{})),
        ?assertEqual(
           {error, invalid_memory_service_reply},
           adk_context:search_memory(Context, <<"remember">>, #{})),
        ?assertEqual(
           {ok, []},
           adk_context_capability:take_effects(Root, EffectId))
    after
        adk_context_capability:stop(Pid)
    end.

%% Hostile adapter callbacks used to prove that the capability, rather than a
%% replaceable service implementation, enforces the tenant boundary.
capabilities(_Handle) -> #{contract_version => 2}.

put(Handle, _Scope, _Name, _Data, _Options) ->
    maps:get(artifact_put_reply, Handle, {error, unsupported}).
put(Handle, Scope, Name, Data, Options, _CallOptions) ->
    put(Handle, Scope, Name, Data, Options).

get(Handle, _Scope, _Name, _Selector) ->
    maps:get(artifact_get_reply, Handle, {error, unsupported}).
get(Handle, Scope, Name, Selector, _CallOptions) ->
    get(Handle, Scope, Name, Selector).

list(Handle, _Scope) ->
    maps:get(artifact_list_reply, Handle, {ok, []}).
list_names(Handle, _Scope, _Options) ->
    maps:get(artifact_names_reply, Handle, {error, unsupported}).
list_versions(Handle, _Scope, _Name, _Options) ->
    maps:get(artifact_versions_reply, Handle, {error, unsupported}).
delete(_Handle, _Scope, _Name, _Selector) -> ok.
delete(Handle, Scope, Name, Selector, _CallOptions) ->
    delete(Handle, Scope, Name, Selector).

add_entry(Handle, _Scope, _Entry, _Options) ->
    maps:get(memory_add_reply, Handle, {error, unsupported}).
add_entry(Handle, Scope, Entry, Options, _CallOptions) ->
    add_entry(Handle, Scope, Entry, Options).
add_events(_Handle, _Scope, _SessionId, _Events, _Options) ->
    {ok, #{added => 0, duplicates => 0, skipped => 0}}.
add_session_to_memory(Handle, Scope, SessionId, Events, Options) ->
    add_events(Handle, Scope, SessionId, Events, Options).
search(Handle, _Scope, _Query, _Options) ->
    maps:get(memory_search_reply, Handle, {error, unsupported}).
search(Handle, Scope, Query, Options, _CallOptions) ->
    search(Handle, Scope, Query, Options).
delete_entry(_Handle, _Scope, _Id) -> ok.
delete_entry(Handle, Scope, Id, _CallOptions) ->
    delete_entry(Handle, Scope, Id).
delete_session(_Handle, _Scope, _SessionId) -> ok.
delete_user(_Handle, _Scope) -> ok.

identity() ->
    #{app_name => ?APP,
      user_id => ?USER,
      session_id => ?SESSION,
      invocation_id => ?INVOCATION}.

scope() -> {session, ?APP, ?USER, ?SESSION}.

memory_scope() -> {user, ?APP, ?USER}.
