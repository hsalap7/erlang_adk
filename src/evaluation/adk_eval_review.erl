%% @doc Deterministic human-review state machine for evaluation findings.
%%
%% Persistence is intentionally delegated to the evaluation store or an
%% operator review system. Revisions and expected-revision transitions make
%% concurrent reviewers safe: terminal decisions are immutable and stale
%% writes fail closed.
-module(adk_eval_review).

-export([new/3, record_decision/5, expire/3, public/1]).

-define(SCHEMA_VERSION, 1).
-define(MAX_REVIEWERS, 16).

-spec new(binary(), map(), map()) -> {ok, map()} | {error, term()}.
new(Id, Subject, Options) when is_map(Subject), is_map(Options) ->
    Allowed = [required_reviewers, expires_at],
    Unknown = maps:keys(maps:without(Allowed, Options)),
    Required = maps:get(required_reviewers, Options, 1),
    ExpiresAt = maps:get(expires_at, Options, null),
    case {Unknown, valid_id(Id), bounded_json(Subject),
          is_integer(Required), Required > 0, Required =< ?MAX_REVIEWERS,
          valid_expiry(ExpiresAt)} of
        {[], true, true, true, true, true, true} ->
            {ok, #{<<"review_schema_version">> => ?SCHEMA_VERSION,
                   <<"review_id">> => Id,
                   <<"revision">> => 0,
                   <<"phase">> => <<"pending">>,
                   <<"subject">> => Subject,
                   <<"required_reviewers">> => Required,
                   <<"expires_at">> => ExpiresAt,
                   <<"decisions">> => []}};
        {[_ | _], _, _, _, _, _, _} ->
            {error, {unknown_eval_review_options, lists:sort(Unknown)}};
        _ -> {error, invalid_eval_review}
    end;
new(_Id, _Subject, _Options) -> {error, invalid_eval_review}.

-spec record_decision(map(), non_neg_integer(), binary(), approve | reject,
                      map()) -> {ok, map()} | {error, term()}.
record_decision(Review0, ExpectedRevision, Reviewer, Decision, Metadata)
  when is_integer(ExpectedRevision), ExpectedRevision >= 0,
       is_map(Metadata) ->
    case validate(Review0) of
        {error, _} = Error -> Error;
        {ok, #{<<"phase">> := Phase}} when Phase =/= <<"pending">> ->
            {error, eval_review_terminal};
        {ok, Review} ->
            Revision = maps:get(<<"revision">>, Review),
            Decisions = maps:get(<<"decisions">>, Review),
            case {Revision =:= ExpectedRevision, valid_id(Reviewer),
                  lists:member(Decision, [approve, reject]),
                  bounded_json(Metadata),
                  reviewer_exists(Reviewer, Decisions)} of
                {false, _, _, _, _} -> {error, stale_eval_review_revision};
                {_, false, _, _, _} -> {error, invalid_eval_reviewer};
                {_, _, false, _, _} -> {error, invalid_eval_review_decision};
                {_, _, _, false, _} -> {error, invalid_eval_review_metadata};
                {_, _, _, _, true} -> {error, duplicate_eval_reviewer};
                {true, true, true, true, false} ->
                    Entry = #{<<"reviewer">> => Reviewer,
                              <<"decision">> => atom_to_binary(Decision),
                              <<"metadata">> => Metadata},
                    Updated = Decisions ++ [Entry],
                    Phase1 = review_phase(
                               Updated,
                               maps:get(<<"required_reviewers">>, Review)),
                    {ok, Review#{<<"revision">> => Revision + 1,
                                <<"phase">> => Phase1,
                                <<"decisions">> => Updated}}
            end
    end;
record_decision(_Review, _Revision, _Reviewer, _Decision, _Metadata) ->
    {error, invalid_eval_review_decision}.

-spec expire(map(), non_neg_integer(), non_neg_integer()) ->
    {ok, map()} | {error, term()}.
expire(Review0, ExpectedRevision, Now)
  when is_integer(ExpectedRevision), ExpectedRevision >= 0,
       is_integer(Now), Now >= 0 ->
    case validate(Review0) of
        {ok, #{<<"phase">> := <<"pending">>,
               <<"revision">> := ExpectedRevision,
               <<"expires_at">> := ExpiresAt} = Review}
          when is_integer(ExpiresAt), Now >= ExpiresAt ->
            {ok, Review#{<<"revision">> => ExpectedRevision + 1,
                         <<"phase">> => <<"expired">>}};
        {ok, #{<<"phase">> := Phase}} when Phase =/= <<"pending">> ->
            {error, eval_review_terminal};
        {ok, #{<<"revision">> := Revision}}
          when Revision =/= ExpectedRevision ->
            {error, stale_eval_review_revision};
        {ok, _} -> {error, eval_review_not_expired};
        {error, _} = Error -> Error
    end;
expire(_Review, _ExpectedRevision, _Now) ->
    {error, invalid_eval_review_expiry}.

-spec public(map()) -> {ok, map()} | {error, term()}.
public(Review) -> validate(Review).

validate(#{<<"review_schema_version">> := ?SCHEMA_VERSION,
           <<"review_id">> := Id,
           <<"revision">> := Revision,
           <<"phase">> := Phase,
           <<"subject">> := Subject,
           <<"required_reviewers">> := Required,
           <<"expires_at">> := ExpiresAt,
           <<"decisions">> := Decisions} = Review) ->
    Expected = [<<"review_schema_version">>, <<"review_id">>, <<"revision">>,
                <<"phase">>, <<"subject">>, <<"required_reviewers">>,
                <<"expires_at">>, <<"decisions">>],
    case {lists:sort(maps:keys(Review)) =:= lists:sort(Expected),
          valid_id(Id), is_integer(Revision), Revision >= 0,
          lists:member(Phase, [<<"pending">>, <<"approved">>,
                               <<"rejected">>, <<"expired">>]),
          bounded_json(Subject), is_integer(Required), Required > 0,
          Required =< ?MAX_REVIEWERS, valid_expiry(ExpiresAt),
          validate_decisions(Decisions, #{})} of
        {true, true, true, true, true, true, true, true, true, true, ok} ->
            {ok, Review};
        _ -> {error, invalid_eval_review}
    end;
validate(_) -> {error, invalid_eval_review}.

validate_decisions([], _Seen) -> ok;
validate_decisions([#{<<"reviewer">> := Reviewer,
                      <<"decision">> := Decision,
                      <<"metadata">> := Metadata} = Entry | Rest], Seen) ->
    Expected = [<<"reviewer">>, <<"decision">>, <<"metadata">>],
    case lists:sort(maps:keys(Entry)) =:= lists:sort(Expected)
         andalso valid_id(Reviewer)
         andalso lists:member(Decision, [<<"approve">>, <<"reject">>])
         andalso bounded_json(Metadata)
         andalso not maps:is_key(Reviewer, Seen) of
        true -> validate_decisions(Rest, Seen#{Reviewer => true});
        false -> error
    end;
validate_decisions(_, _Seen) -> error.

review_phase(Decisions, Required) ->
    case lists:any(fun(#{<<"decision">> := Value}) ->
                           Value =:= <<"reject">>
                   end, Decisions) of
        true -> <<"rejected">>;
        false when length(Decisions) >= Required -> <<"approved">>;
        false -> <<"pending">>
    end.

reviewer_exists(Reviewer, Decisions) ->
    lists:any(fun(#{<<"reviewer">> := Existing}) ->
                      Existing =:= Reviewer
              end, Decisions).

valid_expiry(null) -> true;
valid_expiry(Value) -> is_integer(Value) andalso Value >= 0.

valid_id(Value) when is_binary(Value), byte_size(Value) > 0,
                     byte_size(Value) =< 256 ->
    try unicode:characters_to_binary(Value) of Value -> true; _ -> false
    catch _:_ -> false end;
valid_id(_) -> false.

bounded_json(Value) ->
    case adk_eval_limits:check(
           Value, #{max_external_bytes => 1048576,
                    max_total_binary_bytes => 1048576,
                    max_binary_bytes => 262144,
                    max_depth => 32, max_nodes => 10000,
                    max_list_length => 10000, max_map_size => 10000}) of
        ok -> json(Value);
        {error, _} -> false
    end.

json(Value) when is_binary(Value) -> true;
json(Value) when is_integer(Value) -> true;
json(Value) when is_float(Value) -> Value =:= Value;
json(true) -> true;
json(false) -> true;
json(null) -> true;
json(Value) when is_list(Value) -> lists:all(fun json/1, Value);
json(Value) when is_map(Value) ->
    lists:all(fun({Key, Nested}) -> is_binary(Key) andalso json(Nested) end,
              maps:to_list(Value));
json(_) -> false.
