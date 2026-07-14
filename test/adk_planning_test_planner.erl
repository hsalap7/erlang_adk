-module(adk_planning_test_planner).
-behaviour(adk_planner).

-export([plan/4, review/6]).

plan(Target, Goal, _Context, Config) ->
    notify(Target, {planner_called, plan, self()}),
    maybe_delay(plan, Config),
    case maps:get(mode, Config, normal) of
        plan_crash -> erlang:error(planner_crash);
        invalid_plan -> {ok, #{<<"not">> => <<"a-plan">>}};
        initial_complete -> {complete, #{<<"answer">> => <<"ready">>}};
        configured_plan -> {ok, maps:get(plan, Config)};
        replan_once ->
            make_plan(<<"test-plan">>, 0, Goal,
                      [step(<<"first">>, <<"error">>, 1)]);
        replan_forever ->
            make_plan(<<"test-plan">>, 0, Goal,
                      [step(<<"revision-0">>, <<"echo">>, 0)]);
        bad_replan ->
            make_plan(<<"test-plan">>, 0, Goal,
                      [step(<<"first">>, <<"echo">>, 1)]);
        _ ->
            Count = maps:get(step_count, Config, 1),
            Steps = [step(integer_to_binary(N), <<"echo">>, N)
                     || N <- lists:seq(1, Count)],
            make_plan(<<"test-plan">>, 0, Goal, Steps)
    end.

review(Target, Plan, _Step, Observation, _Context, Config) ->
    notify(Target, {planner_called, review, self()}),
    maybe_delay(review, Config),
    case maps:get(mode, Config, normal) of
        review_crash -> erlang:error(planner_review_crash);
        invalid_review -> invalid_decision;
        review_fail -> {fail, deliberately_failed};
        complete_after_step ->
            {complete, maps:get(<<"output">>, Observation, null)};
        replan_once ->
            case maps:get(<<"revision">>, Plan) of
                0 ->
                    Goal = maps:get(<<"goal">>, Plan),
                    {ok, NewPlan} = make_plan(
                                      maps:get(<<"id">>, Plan), 1, Goal,
                                      [step(<<"recovered">>,
                                            <<"echo">>, 42)]),
                    {replan, NewPlan};
                _ -> continue
            end;
        replan_forever ->
            Revision = maps:get(<<"revision">>, Plan) + 1,
            Goal = maps:get(<<"goal">>, Plan),
            StepId = <<"revision-", (integer_to_binary(Revision))/binary>>,
            {ok, NewPlan} = make_plan(
                              maps:get(<<"id">>, Plan), Revision, Goal,
                              [step(StepId, <<"echo">>, Revision)]),
            {replan, NewPlan};
        bad_replan ->
            Goal = maps:get(<<"goal">>, Plan),
            {ok, NewPlan} = make_plan(
                              <<"different-plan">>, 7, Goal,
                              [step(<<"bad">>, <<"echo">>, 7)]),
            {replan, NewPlan};
        _ -> continue
    end.

make_plan(Id, Revision, Goal, Steps) ->
    adk_plan:new(Id, Revision, Goal, Steps,
                 #{suite => <<"planning-runtime">>,
                   api_key => <<"must-be-pruned">>}).

step(Id, Mode, Value) ->
    {ok, Step} = adk_plan:step(
                   Id, <<"Execute a deterministic fixture action">>,
                   #{<<"mode">> => Mode, <<"value">> => Value}),
    Step.

maybe_delay(Phase, Config) ->
    Delay = case {Phase, maps:get(mode, Config, normal)} of
        {plan, plan_timeout} -> maps:get(delay_ms, Config, 500);
        {review, review_timeout} -> maps:get(delay_ms, Config, 500);
        _ -> maps:get(delay_ms, Config, 0)
    end,
    case Delay of
        Milliseconds when is_integer(Milliseconds), Milliseconds > 0 ->
            timer:sleep(Milliseconds);
        _ -> ok
    end.

notify(Pid, Message) when is_pid(Pid) -> Pid ! Message;
notify(_, _) -> ok.
