-module(adk_session_query_test).

-include_lib("eunit/include/eunit.hrl").

-define(APP, <<"session-query-app">>).
-define(USER, <<"session-query-user">>).
-define(SECRET,
        <<"0123456789abcdef0123456789abcdef">>).

setup() ->
    ok = erlang_adk_session:init(),
    ets:delete_all_objects(adk_sessions),
    ok.

cleanup(_) ->
    ets:delete_all_objects(adk_sessions),
    ok.

session_query_test_() ->
    {setup,
     fun setup/0,
     fun cleanup/1,
     [fun deterministic_pagination_and_cursor_validation/0,
      fun event_pagination_is_snapshot_and_query_bound/0,
      fun filtered_events_and_state_are_json_safe/0,
      fun rewind_plan_materializes_an_immutable_branch/0,
      fun head_branch_copies_only_safe_local_state/0,
      fun stale_and_modified_plans_are_rejected/0,
      fun shared_state_replay_is_blocked/0,
      fun transient_state_replay_is_blocked/0,
      fun concurrent_session_queries_remain_isolated/0]}.

deterministic_pagination_and_cursor_validation() ->
    lists:foreach(
      fun(Id) ->
          {ok, _} = erlang_adk_session:create_session(
                      ?APP, ?USER, #{session_id => Id})
      end,
      [<<"c">>, <<"a">>, <<"b">>]),
    %% Creation uses millisecond wall time. Pin fixture timestamps so the test
    %% verifies timestamp-descending order plus the ID tie-break without
    %% depending on whether these three calls cross a millisecond boundary.
    true = ets:update_element(
             adk_sessions, {?APP, ?USER, <<"c">>}, {4, 1}),
    true = ets:update_element(
             adk_sessions, {?APP, ?USER, <<"a">>}, {4, 2}),
    true = ets:update_element(
             adk_sessions, {?APP, ?USER, <<"b">>}, {4, 2}),
    Opts = #{limit => 2, cursor_secret => ?SECRET},
    {ok, First1} = adk_session_query:list(
                     erlang_adk_session, ?APP, ?USER, Opts),
    {ok, First2} = adk_session_query:list(
                     erlang_adk_session, ?APP, ?USER, Opts),
    ?assertEqual(First1, First2),
    Cursor = maps:get(next_cursor, First1),
    ?assert(is_binary(Cursor)),
    {ok, Second} = adk_session_query:list(
                     erlang_adk_session, ?APP, ?USER,
                     Opts#{cursor => Cursor}),
    Ids = [maps:get(id, Meta) || Meta <-
            maps:get(sessions, First1) ++ maps:get(sessions, Second)],
    ?assertEqual([<<"a">>, <<"b">>, <<"c">>], Ids),
    ?assertEqual(null, maps:get(next_cursor, Second)),

    Forged = forge_cursor(Cursor),
    ?assertEqual(
       {error, invalid_cursor},
       adk_session_query:list(
         erlang_adk_session, ?APP, ?USER,
         Opts#{cursor => Forged})),
    ?assertEqual(
       {error, invalid_cursor},
       adk_session_query:list(
         erlang_adk_session, ?APP, ?USER,
         Opts#{cursor => forge_padding_bits(Cursor)})),

    {ok, _} = erlang_adk_session:create_session(
                ?APP, ?USER, #{session_id => <<"d">>}),
    ?assertEqual(
       {error, stale_cursor},
       adk_session_query:list(
         erlang_adk_session, ?APP, ?USER,
         Opts#{cursor => Cursor})).

event_pagination_is_snapshot_and_query_bound() ->
    SessionId = <<"event-pages">>,
    OtherId = <<"other-event-pages">>,
    {ok, _} = erlang_adk_session:create_session(
                ?APP, ?USER, #{session_id => SessionId}),
    {ok, _} = erlang_adk_session:create_session(
                ?APP, ?USER, #{session_id => OtherId}),
    Events = [adk_event:new(<<"agent">>, integer_to_binary(N))
              || N <- lists:seq(1, 3)],
    lists:foreach(
      fun(Event) ->
          ok = erlang_adk_session:add_event(
                 ?APP, ?USER, SessionId, Event)
      end, Events),
    Opts = #{event_limit => 2, cursor_secret => ?SECRET},
    {ok, First1} = adk_session_query:get(
                     erlang_adk_session, ?APP, ?USER, SessionId, Opts),
    {ok, First2} = adk_session_query:get(
                     erlang_adk_session, ?APP, ?USER, SessionId, Opts),
    ?assertEqual(First1, First2),
    Cursor = maps:get(next_cursor, maps:get(event_page, First1)),
    {ok, Second} = adk_session_query:get(
                     erlang_adk_session, ?APP, ?USER, SessionId,
                     Opts#{event_cursor => Cursor}),
    ?assertEqual(1, length(maps:get(events, Second))),
    ?assertEqual(null,
                 maps:get(next_cursor, maps:get(event_page, Second))),
    ?assertEqual(
       {error, invalid_cursor},
       adk_session_query:get(
         erlang_adk_session, ?APP, ?USER, OtherId,
         Opts#{event_cursor => Cursor})),
    ?assertEqual(
       {error, invalid_cursor},
       adk_session_query:get(
         erlang_adk_session, ?APP, ?USER, SessionId,
         Opts#{event_cursor => Cursor,
               include_authors => [<<"agent">>]})),
    ok = erlang_adk_session:add_event(
           ?APP, ?USER, SessionId,
           adk_event:new(<<"agent">>, <<"four">>)),
    ?assertEqual(
       {error, stale_cursor},
       adk_session_query:get(
         erlang_adk_session, ?APP, ?USER, SessionId,
         Opts#{event_cursor => Cursor})).

filtered_events_and_state_are_json_safe() ->
    {ok, _} = erlang_adk_session:create_session(
                ?APP, ?USER,
                #{session_id => <<"safe-query">>,
                  state => #{<<"topic">> => <<"otp">>,
                             access_token => self(),
                             <<"client-secret">> => <<"hidden">>}}),
    User = adk_event:new(<<"user">>, <<"hello">>),
    Tool = adk_event:new(
             <<"tool">>,
             {tool_response, <<"oauth">>,
              #{<<"access_token">> => self(), <<"value">> => 42}}),
    Final = adk_event:new(<<"agent">>, <<"done">>, #{is_final => true}),
    lists:foreach(
      fun(Event) ->
          ok = erlang_adk_session:add_event(
                 ?APP, ?USER, <<"safe-query">>, Event)
      end,
      [User, Tool, Final]),
    {ok, Query} = adk_session_query:get(
                    erlang_adk_session, ?APP, ?USER, <<"safe-query">>,
                    #{cursor_secret => ?SECRET,
                      include_authors => [<<"tool">>]}),
    ?assertEqual(#{<<"topic">> => <<"otp">>}, maps:get(state, Query)),
    [EncodedTool] = maps:get(events, Query),
    ?assertEqual(false, contains_sensitive_key(EncodedTool)),
    ?assert(is_binary(jsx:encode(maps:get(events, Query)))),
    Content = maps:get(<<"content">>, EncodedTool),
    ?assertEqual(#{<<"value">> => 42},
                 maps:get(<<"result">>, Content)).

rewind_plan_materializes_an_immutable_branch() ->
    SourceId = <<"rewind-source">>,
    TargetId = <<"rewind-target">>,
    {ok, _} = erlang_adk_session:create_session(
                ?APP, ?USER, #{session_id => SourceId}),
    E1 = adk_event:with_state_delta(
           adk_event:new(<<"user">>, <<"one">>), #{<<"step">> => 1}),
    E2 = adk_event:with_state_delta(
           adk_event:new(<<"agent">>, <<"two">>), #{<<"step">> => 2}),
    E3 = adk_event:new(<<"agent">>, <<"three">>),
    lists:foreach(
      fun(Event) ->
          ok = erlang_adk_session:add_event(
                 ?APP, ?USER, SourceId, Event)
      end,
      [E1, E2, E3]),
    {ok, SourceBefore} = erlang_adk_session:get_session(
                           ?APP, ?USER, SourceId),
    {ok, Plan} = adk_session_query:plan_rewind(
                   erlang_adk_session, ?APP, ?USER, SourceId,
                   {index, 2}, #{}),
    ?assertEqual(2, maps:get(retained_events, Plan)),
    ?assertEqual(false, maps:get(destructive, Plan)),
    {ok, Result} = adk_session_query:apply_plan(
                     erlang_adk_session, Plan,
                     #{target_session_id => TargetId}),
    ?assertEqual(TargetId, maps:get(session_id, Result)),
    ?assertEqual(2, maps:get(events_copied, Result)),
    {ok, SourceAfter} = erlang_adk_session:get_session(
                          ?APP, ?USER, SourceId),
    ?assertEqual(SourceBefore, SourceAfter),
    {ok, Target} = erlang_adk_session:get_session(
                     ?APP, ?USER, TargetId),
    ?assertEqual(2, length(maps:get(events, Target))),
    ?assertEqual(2, maps:get(<<"step">>, maps:get(state, Target))),
    ?assertEqual(
       {error, destructive_rewind_unsupported},
       adk_session_query:rewind(
         erlang_adk_session, ?APP, ?USER, SourceId,
         {index, 1}, #{destructive => true})).

head_branch_copies_only_safe_local_state() ->
    SourceId = <<"head-branch-source">>,
    TargetId = <<"head-branch-target">>,
    {ok, _} = erlang_adk_session:create_session(
                ?APP, ?USER,
                #{session_id => SourceId,
                  state => #{<<"seed">> => 7,
                             <<"temp:working">> => true,
                             <<"__adk_internal">> => <<"skip">>,
                             <<"access_token">> => <<"hidden">>}}),
    Event = adk_event:with_state_delta(
              adk_event:new(<<"agent">>, <<"advanced">>),
              #{<<"step">> => 2}),
    ok = erlang_adk_session:add_event(?APP, ?USER, SourceId, Event),
    {ok, Plan} = adk_session_query:plan_branch(
                   erlang_adk_session, ?APP, ?USER, SourceId, #{}),
    ?assertEqual(current_session_local,
                 maps:get(state_strategy, Plan)),
    ?assertEqual(#{<<"seed">> => 7, <<"step">> => 2},
                 maps:get(initial_state, Plan)),
    {ok, _} = adk_session_query:apply_plan(
                erlang_adk_session, Plan,
                #{target_session_id => TargetId}),
    {ok, Target} = erlang_adk_session:get_session(
                     ?APP, ?USER, TargetId),
    ?assertEqual(#{<<"seed">> => 7, <<"step">> => 2},
                 maps:get(state, Target)).

stale_and_modified_plans_are_rejected() ->
    SourceId = <<"stale-plan-source">>,
    {ok, _} = erlang_adk_session:create_session(
                ?APP, ?USER, #{session_id => SourceId}),
    ok = erlang_adk_session:add_event(
           ?APP, ?USER, SourceId,
           adk_event:new(<<"user">>, <<"one">>)),
    {ok, Plan} = adk_session_query:plan_branch(
                   erlang_adk_session, ?APP, ?USER, SourceId, #{}),
    [Only] = maps:get(events, Plan),
    ForgedEvent = Only#{<<"author">> => <<"attacker">>},
    ForgedPlan = Plan#{events => [ForgedEvent]},
    ?assertEqual(
       {error, invalid_branch_plan},
       adk_session_query:apply_plan(
         erlang_adk_session, ForgedPlan,
         #{target_session_id => <<"forged-target">>})),
    ok = erlang_adk_session:add_event(
           ?APP, ?USER, SourceId,
           adk_event:new(<<"agent">>, <<"two">>)),
    ?assertEqual(
       {error, stale_branch_plan},
       adk_session_query:apply_plan(
         erlang_adk_session, Plan,
         #{target_session_id => <<"stale-target">>})).

shared_state_replay_is_blocked() ->
    SourceId = <<"shared-state-source">>,
    {ok, _} = erlang_adk_session:create_session(
                ?APP, ?USER, #{session_id => SourceId}),
    Event = adk_event:with_state_delta(
              adk_event:new(<<"agent">>, <<"theme">>),
              #{<<"user:theme">> => <<"dark">>}),
    ok = erlang_adk_session:add_event(?APP, ?USER, SourceId, Event),
    {ok, Plan} = adk_session_query:plan_branch(
                   erlang_adk_session, ?APP, ?USER, SourceId, #{}),
    ?assertEqual(
       {error, {shared_state_replay_blocked, [<<"user:theme">>]}},
       adk_session_query:apply_plan(
         erlang_adk_session, Plan,
         #{target_session_id => <<"shared-state-target">>})),
    ?assertEqual(
       {error, not_found},
       erlang_adk_session:get_session(
         ?APP, ?USER, <<"shared-state-target">>)).

transient_state_replay_is_blocked() ->
    SourceId = <<"transient-state-source">>,
    {ok, _} = erlang_adk_session:create_session(
                ?APP, ?USER, #{session_id => SourceId}),
    Event = adk_event:with_state_delta(
              adk_event:new(<<"agent">>, <<"working">>),
              #{<<"temp:invocation">> => <<"do-not-copy">>}),
    ok = erlang_adk_session:add_event(?APP, ?USER, SourceId, Event),
    {ok, Plan} = adk_session_query:plan_branch(
                   erlang_adk_session, ?APP, ?USER, SourceId, #{}),
    ?assertEqual(
       {error, {transient_state_replay_blocked,
                [<<"temp:invocation">>]}},
       adk_session_query:apply_plan(
         erlang_adk_session, Plan,
         #{target_session_id => <<"transient-state-target">>})).

concurrent_session_queries_remain_isolated() ->
    Count = 24,
    lists:foreach(
      fun(N) ->
          Id = session_id(N),
          {ok, _} = erlang_adk_session:create_session(
                      ?APP, ?USER, #{session_id => Id}),
          ok = erlang_adk_session:add_event(
                 ?APP, ?USER, Id,
                 adk_event:new(<<"agent">>, Id))
      end,
      lists:seq(1, Count)),
    Parent = self(),
    [spawn(fun() ->
         Id = session_id(N),
         Result = adk_session_query:get(
                    erlang_adk_session, ?APP, ?USER, Id,
                    #{cursor_secret => ?SECRET}),
         Parent ! {query_result, N, Result}
     end) || N <- lists:seq(1, Count)],
    Results = collect_results(Count, #{}),
    lists:foreach(
      fun(N) ->
          {ok, Query} = maps:get(N, Results),
          [Event] = maps:get(events, Query),
          Content = maps:get(<<"content">>, Event),
          ?assertEqual(session_id(N), maps:get(<<"text">>, Content))
      end,
      lists:seq(1, Count)).

collect_results(0, Acc) -> Acc;
collect_results(Remaining, Acc) ->
    receive
        {query_result, N, Result} ->
            collect_results(Remaining - 1, Acc#{N => Result})
    after 5000 ->
        error({query_timeout, Remaining})
    end.

session_id(N) ->
    <<"concurrent-", (integer_to_binary(N))/binary>>.

forge_cursor(Cursor) ->
    %% Change significant base64url bits. The final character can contain only
    %% padding bits and therefore is not a reliable tamper operation.
    <<First, Rest/binary>> = Cursor,
    Replacement = case First of $A -> $B; _ -> $A end,
    <<Replacement, Rest/binary>>.

forge_padding_bits(Cursor) ->
    Size = byte_size(Cursor),
    <<Prefix:(Size - 1)/binary, Last>> = Cursor,
    %% A 137-byte cursor has four unused bits in its final base64url symbol.
    %% Preserve its two significant bits while changing the unused bits.
    Alphabet = <<"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_">>,
    {Index, 1} = binary:match(Alphabet, <<Last>>),
    ReplacementIndex = (Index band 16#30) bor ((Index + 1) band 16#0f),
    <<Replacement>> = binary:part(Alphabet, ReplacementIndex, 1),
    <<Prefix/binary, Replacement>>.

contains_sensitive_key(Map) when is_map(Map) ->
    lists:any(
      fun({Key, Value}) ->
          adk_context_guard:sensitive_key(Key) orelse
          contains_sensitive_key(Value)
      end,
      maps:to_list(Map));
contains_sensitive_key(List) when is_list(List) ->
    lists:any(fun contains_sensitive_key/1, List);
contains_sensitive_key(_) -> false.
