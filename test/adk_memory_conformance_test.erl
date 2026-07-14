-module(adk_memory_conformance_test).
-include_lib("eunit/include/eunit.hrl").

memory_adapter_conformance_test_() ->
    [adapter_group(ets), adapter_group(mnesia)].

adapter_group(ets) ->
    {setup,
     fun() ->
         {ok, Pid} = adk_memory_ets:start_link(#{}),
         {adk_memory_ets, Pid}
     end,
     fun({Module, Pid}) -> Module:stop(Pid) end,
     fun(Adapter) -> conformance_cases(Adapter, <<"ets">>) end};
adapter_group(mnesia) ->
    {setup,
     fun setup_mnesia/0,
     fun cleanup_mnesia/1,
     fun(Adapter) -> conformance_cases(Adapter, <<"mnesia">>) end}.

conformance_cases({Module, Pid}, Suffix) ->
    Scope = scope(<<"main-", Suffix/binary>>),
    OtherUser = {user, <<"memory-app">>, <<"other-user-", Suffix/binary>>},
    OtherApp = {user, <<"other-app">>, <<"memory-user-", Suffix/binary>>},
    [?_test(capabilities_case(Module, Pid)),
     ?_test(scoped_idempotency_case(Module, Pid, Scope, OtherUser, OtherApp)),
     ?_test(event_ingestion_case(Module, Pid, Scope)),
     ?_test(lifecycle_case(Module, Pid, Scope))].

capabilities_case(Module, Pid) ->
    Caps = Module:capabilities(Pid),
    ?assertEqual(2, maps:get(contract_version, Caps)),
    ?assertEqual(app_user, maps:get(scope, Caps)),
    ?assertEqual(lexical_overlap, maps:get(search, Caps)),
    ?assertEqual(true, maps:get(idempotent_ingestion, Caps)).

scoped_idempotency_case(Module, Pid, Scope, OtherUser, OtherApp) ->
    Input = #{content => <<"Erlang lightweight processes isolate memory">>,
              metadata => #{<<"topic">> => <<"beam">>,
                            <<"password">> => <<"must-not-survive">>},
              provenance => #{session_id => <<"scope-session">>,
                              event_ids => [<<"manual-1">>],
                              author => <<"user">>, timestamp => 100}},
    Opts = #{idempotency_key => <<"manual-entry-1">>},
    {ok, First} = Module:add_entry(Pid, Scope, Input, Opts),
    {ok, Duplicate} = Module:add_entry(Pid, Scope, Input, Opts),
    ?assertEqual(maps:get(id, First), maps:get(id, Duplicate)),
    ?assertEqual(adk_secret_redactor:marker(),
                 maps:get(<<"password">>, maps:get(metadata, First))),

    {ok, [Hit]} = Module:search(
                    Pid, Scope, <<"lightweight isolate">>,
                    #{filter => #{<<"topic">> => <<"beam">>}, limit => 5}),
    ?assertEqual(maps:get(id, First), maps:get(id, Hit)),
    ?assertEqual(lexical_overlap, maps:get(score_type, Hit)),
    ?assertEqual(1.0, maps:get(score, Hit)),
    ?assertEqual(<<"scope-session">>,
                 maps:get(session_id, maps:get(provenance, Hit))),
    {ok, []} = Module:search(Pid, OtherUser, <<"lightweight">>, #{limit => 5}),
    {ok, []} = Module:search(Pid, OtherApp, <<"lightweight">>, #{limit => 5}),

    Conflict = Input#{content => <<"different content">>},
    ?assertEqual({error, idempotency_conflict},
                 unwrap_transaction_error(
                   Module:add_entry(Pid, Scope, Conflict, Opts))).

event_ingestion_case(Module, Pid, Scope) ->
    SessionId = <<"events-session">>,
    User = adk_event:new(<<"user">>, <<"Remember OTP supervision trees">>),
    Agent = adk_event:new(<<"Writer">>, <<"Supervisors restart workers">>),
    Partial = adk_event:new(<<"Writer">>, <<"unfinished secret">>,
                            #{partial => true}),
    Control = adk_event:new(<<"runner">>, <<"internal continuation">>),
    Secret = adk_event:new(<<"user">>,
                           <<"password=never-store-this">>),
    Events = [User, Agent, Partial, Control, Secret],
    {ok, First} = Module:add_events(Pid, Scope, SessionId, Events, #{}),
    ?assertEqual(2, maps:get(added, First)),
    ?assertEqual(3, maps:get(skipped, First)),
    {ok, Retry} = Module:add_session_to_memory(
                    Pid, Scope, SessionId, Events, #{}),
    ?assertEqual(0, maps:get(added, Retry)),
    ?assertEqual(2, maps:get(duplicates, Retry)),
    {ok, [_]} = Module:search(Pid, Scope, <<"supervision trees">>,
                              #{limit => 5}),
    {ok, []} = Module:search(Pid, Scope, <<"never store">>, #{limit => 5}),
    ok = Module:delete_session(Pid, Scope, SessionId),
    {ok, []} = Module:search(Pid, Scope, <<"supervision trees">>,
                             #{limit => 5}),
    ?assertEqual({error, not_found},
                 Module:delete_session(Pid, Scope, SessionId)).

lifecycle_case(Module, Pid, Scope) ->
    {ok, One} = Module:add_entry(
                  Pid, Scope,
                  #{content => <<"erase one entry marker">>, metadata => #{}},
                  #{}),
    ok = Module:delete_entry(Pid, Scope, maps:get(id, One)),
    ?assertEqual({error, not_found},
                 Module:delete_entry(Pid, Scope, maps:get(id, One))),
    {ok, _} = Module:add_entry(
                Pid, Scope,
                #{content => <<"erase complete user marker">>, metadata => #{}},
                #{}),
    ok = Module:delete_user(Pid, Scope),
    {ok, []} = Module:search(Pid, Scope, <<"complete user">>, #{limit => 5}),
    ?assertEqual({error, not_found}, Module:delete_user(Pid, Scope)).

setup_mnesia() ->
    {ok, Pid} = adk_memory_mnesia:start_link(#{}),
    lists:foreach(fun(Table) -> {atomic, ok} = mnesia:clear_table(Table) end,
                  adk_memory_mnesia:table_names()),
    {adk_memory_mnesia, Pid}.

cleanup_mnesia({Module, Pid}) ->
    Module:stop(Pid),
    lists:foreach(fun(Table) -> mnesia:clear_table(Table) end,
                  adk_memory_mnesia:table_names()),
    ok.

scope(User) -> {user, <<"memory-app">>, User}.

unwrap_transaction_error({error, {memory_transaction_failed, Reason}}) ->
    {error, Reason};
unwrap_transaction_error(Reply) -> Reply.
